# typed: false
# frozen_string_literal: true

require "abstract_command"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "tmpdir"
require "uri"

module Homebrew
  module Cmd
    class Newest < AbstractCommand
      cmd_args do
        description <<~EOS
          List the newest formulae and casks in a table with their name, add date,
          homepage, and description.
        EOS

        switch "--formula",
               description: "List only formulae."
        switch "--cask",
               description: "List only casks."
        switch "-v", "--verbose",
               description: "Print progress while gathering newest entries."
        switch "-d", "--debug",
               description: "Print detailed progress and subprocess failures."
        flag "-n", "--count=",
             description: "Number of entries to show for each selected type."
        flag "--width=",
             description: "Target table width. Defaults to $COLUMNS or 140."
      end

      def run
        BrewNewest.new.run(args)
      end
    end
  end
end

class BrewNewest
  include Utils::Output::Mixin

  GITHUB_API = "https://api.github.com".freeze
  DEFAULT_WIDTH = 140
  DEFAULT_COUNT = 10
  DATE_MARKER = "__BREW_NEWEST_DATE__".freeze
  Item = Struct.new(:name, :date, :homepage, :desc, keyword_init: true)

  def run(args)
    @verbose = args.verbose? || args.debug?
    @debug = args.debug?

    count = Integer(args.count || DEFAULT_COUNT)
    odie "--count must be greater than 0" if count <= 0

    width = args.width ? Integer(args.width) : default_width
    odie "--width must be at least 80" if width < 80

    selections = selected_types(args)
    outputs = selections.map do |type|
      [type, newest_items(type, count)]
    end

    outputs.each_with_index do |(type, items), index|
      puts if index.positive?
      puts title_for(type)
      puts render_table(items, width)
    end
  rescue ArgumentError => e
    odie e.message
  end

  private

  def selected_types(args)
    selected = []
    selected << :formula if args.formula?
    selected << :cask if args.cask?
    selected = %i[formula cask] if selected.empty?
    selected
  end

  def newest_items(type, count)
    trace "Collecting newest #{type}s"
    candidate_count = [count * 10, count + 20].max
    additions = local_additions(type, candidate_count)
    trace "Local #{type} additions found: #{additions.length}"
    if additions.length < count
      additions = remote_git_additions(type, candidate_count)
      trace "Remote git #{type} additions found: #{additions.length}"
    end
    if additions.length < count
      additions = github_additions(type, candidate_count)
      trace "GitHub API #{type} additions found: #{additions.length}"
    end
    odie "Unable to determine newest #{type}s." if additions.empty?

    items = []
    additions.each do |entry|
      info = fetch_metadata_entry(type, entry[:token])
      next if info.nil?

      items << Item.new(
        name:     info.fetch(:name),
        date:     entry.fetch(:date),
        homepage: info.fetch(:homepage),
        desc:     info.fetch(:desc),
      )
      break if items.length >= count
    end

    odie "Unable to find available newest #{type}s." if items.empty?

    items
  end

  def local_additions(type, count)
    repo = local_repo_path(type)
    trace "Checking local #{type} repo: #{repo.inspect}"
    return [] unless repo && File.directory?(repo)

    scope = type == :formula ? "Formula" : "Casks"
    stdout, stderr, status = run_command(
      "git", "-C", repo, "log", "--diff-filter=A", "--name-only", "--format=#{DATE_MARKER}%aI", "--", scope
    )
    return [] unless status.success?

    parse_git_log(stdout, type, count)
  rescue Errno::ENOENT
    []
  end

  def github_additions(type, count)
    repo = github_repo(type)
    path_prefix = type == :formula ? "Formula/" : "Casks/"
    results = []
    page = 1

    while results.length < count && page <= 10
      trace "Querying GitHub API for #{type} commits page #{page}"
      commits = github_get_json("/repos/#{repo}/commits?per_page=100&page=#{page}")
      break unless commits.is_a?(Array) && !commits.empty?

      commits.each do |commit_summary|
        commit = github_get_json(URI(commit_summary.fetch("url")).request_uri)
        next unless commit.is_a?(Hash)

        date = commit.dig("commit", "author", "date")
        next if date.nil?

        Array(commit["files"]).each do |file|
          next unless file["status"] == "added"

          file_path = file["filename"]
          next unless file_path&.start_with?(path_prefix)

          token = token_from_path(file_path)
          next if token.nil? || results.any? { |entry| entry[:token] == token }

          results << { token:, date: date[0, 10] }
          return results if results.length >= count
        end
      end

      page += 1
    end

    results
  rescue StandardError
    []
  end

  def remote_git_additions(type, count)
    repo = remote_cache_path(type)
    remote = remote_git_url(type)
    FileUtils.mkdir_p(File.dirname(repo))
    trace "Checking remote git fallback for #{type}: #{remote}"

    unless Dir.exist?(repo)
      trace "Cloning shallow remote cache into #{repo}"
      stdout, stderr, status = run_command(
        "git", "clone", "--bare", "--filter=blob:none", "--single-branch", "--branch", "main",
        "--depth=500", remote, repo
      )
      return [] unless status.success?
    end

    trace "Refreshing remote git cache for #{type}"
    stdout, stderr, status = run_command(
      "git", "-C", repo, "fetch", "--force", "--filter=blob:none", "--update-shallow", "--depth=500", "origin", "main"
    )
    return [] unless status.success?

    results = remote_git_log(repo, type, count)
    deepen_attempts = 0

    while results.length < count && deepen_attempts < 8
      trace "Deepening remote git cache for #{type} (attempt #{deepen_attempts + 1})"
      stdout, stderr, status = run_command(
        "git", "-C", repo, "fetch", "--deepen=1000", "--filter=blob:none", "origin", "main"
      )
      break unless status.success?

      results = remote_git_log(repo, type, count)
      deepen_attempts += 1
    end

    results
  rescue Errno::ENOENT
    []
  end

  def remote_git_log(repo, type, count)
    scope = type == :formula ? "Formula" : "Casks"
    stdout, stderr, status = run_command(
      "git", "-C", repo, "log", "--diff-filter=A", "--name-only", "--format=#{DATE_MARKER}%aI", "--", scope
    )
    return [] unless status.success?

    parse_git_log(stdout, type, count)
  end

  def fetch_metadata_entry(type, name)
    flag = type == :formula ? "--formula" : "--cask"
    trace "Fetching metadata for #{type}: #{name}"
    stdout, stderr, status = run_command(brew_binary, "info", "--json=v2", flag, name)
    return nil unless status.success?

    json = JSON.parse(stdout)
    key = type == :formula ? "formulae" : "casks"
    entry = Array(json[key]).first
    return nil if entry.nil?

    token = type == :formula ? entry.fetch("name") : entry.fetch("token")
    display_name = if type == :formula
      entry.fetch("full_name", token)
    else
      entry.fetch("full_token", token)
    end

    {
      name:     display_name,
      homepage: entry.fetch("homepage", "-"),
      desc:     entry.fetch("desc", "-"),
    }
  rescue JSON::ParserError => e
    odie "Failed to parse metadata for newest #{type}s: #{e.message}"
  end

  def render_table(items, width)
    name_width = [items.map { |item| item.name.length }.max || 4, 18].max
    name_width = [name_width, 32].min
    date_width = 10
    separator = "  "
    fixed = name_width + date_width + (separator.length * 3)
    remaining = [width - fixed, 40].max
    home_width = [[remaining / 2, 32].max, 56].min
    desc_width = [remaining - home_width, 24].max

    lines = []
    lines << row("Name", "Date", "Homepage", "Description", name_width, date_width, home_width, desc_width)
    lines << row("-" * name_width, "-" * date_width, "-" * home_width, "-" * desc_width,
                 name_width, date_width, home_width, desc_width)

    items.each do |item|
      lines << row(
        truncate(item.name, name_width),
        item.date,
        truncate(item.homepage, home_width),
        truncate(item.desc, desc_width),
        name_width,
        date_width,
        home_width,
        desc_width,
      )
    end

    lines.join("\n")
  end

  def row(name, date, homepage, desc, name_width, date_width, home_width, desc_width)
    format(
      "%-#{name_width}s  %-#{date_width}s  %-#{home_width}s  %-#{desc_width}s",
      name,
      date,
      homepage,
      desc,
    ).rstrip
  end

  def truncate(text, width)
    value = text.to_s.gsub(/\s+/, " ").strip
    return value if value.length <= width

    "#{value[0, width - 3]}..."
  end

  def parse_git_log(stdout, type, count)
    current_date = nil
    results = []

    stdout.each_line do |line|
      line = line.chomp
      next if line.empty?

      if line.start_with?(DATE_MARKER)
        current_date = line.delete_prefix(DATE_MARKER)[0, 10]
        next
      end

      token = token_from_path(line)
      next if token.nil?
      next unless path_matches_type?(line, type)
      next if results.any? { |entry| entry[:token] == token }

      results << { token:, date: current_date }
      break if results.length >= count
    end

    results
  end

  def token_from_path(path)
    return nil unless path.end_with?(".rb")

    File.basename(path, ".rb")
  end

  def path_matches_type?(path, type)
    if type == :formula
      path.start_with?("Formula/")
    else
      path.start_with?("Casks/")
    end
  end

  def local_repo_path(type)
    tap = type == :formula ? "homebrew/core" : "homebrew/cask"
    stdout, stderr, status = run_command(brew_binary, "--repo", tap)
    return nil unless status.success?

    stdout.strip
  rescue Errno::ENOENT
    nil
  end

  def github_repo(type)
    type == :formula ? "Homebrew/homebrew-core" : "Homebrew/homebrew-cask"
  end

  def remote_git_url(type)
    type == :formula ? "https://github.com/Homebrew/homebrew-core.git" : "https://github.com/Homebrew/homebrew-cask.git"
  end

  def remote_cache_path(type)
    File.join(Dir.tmpdir, "brew-newest-cache", "#{type}.git")
  end

  def github_get_json(path)
    gh_path = path.sub(%r{\A/}, "")
    stdout, stderr, status = run_command("gh", "api", gh_path)
    return JSON.parse(stdout) if status.success?

    debug "Falling back to direct GitHub HTTP for #{path}"
    uri = URI("#{GITHUB_API}#{path}")
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "application/vnd.github+json"
      request["User-Agent"] = "brew-newest"
      http.request(request)
    end

    return nil unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue Errno::ENOENT
    debug "GitHub CLI unavailable, using direct GitHub HTTP for #{path}"
    uri = URI("#{GITHUB_API}#{path}")
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "application/vnd.github+json"
      request["User-Agent"] = "brew-newest"
      http.request(request)
    end

    return nil unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  end

  def brew_binary
    ENV["HOMEBREW_BREW_FILE"] || "brew"
  end

  def title_for(type)
    type == :formula ? "Newest Formulae" : "Newest Casks"
  end

  def default_width
    columns = ENV["COLUMNS"].to_i
    columns.positive? ? columns : DEFAULT_WIDTH
  end

  def trace(message)
    $stderr.puts "==> #{message}" if @verbose
  end

  def debug(message)
    $stderr.puts "debug: #{message}" if @debug
  end

  def run_command(*command)
    debug "Running: #{command.join(' ')}"
    stdout, stderr, status = Open3.capture3(*command)
    debug "Exit #{status.exitstatus}: #{stderr.strip}" if @debug && !status.success? && !stderr.to_s.strip.empty?
    [stdout, stderr, status]
  end
end

Homebrew::Cmd::Newest.new.run if $PROGRAM_NAME == __FILE__
