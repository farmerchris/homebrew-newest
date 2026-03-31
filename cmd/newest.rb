# typed: false
# frozen_string_literal: true

require "abstract_command"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "thread"
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
        switch "-o", "--offline",
               description: "Use only local taps and cached metadata; do not fetch from the network."
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
  INITIAL_REMOTE_DEPTH = 200
  REMOTE_DEEPEN_STEP = 2000
  MAX_REMOTE_DEEPENS = 4
  INFO_WORKERS = 3
  INFO_BATCH_SIZE = 8
  DATE_MARKER = "__BREW_NEWEST_DATE__".freeze
  Item = Struct.new(:name, :date, :homepage, :desc, keyword_init: true)

  def run(args)
    @verbose = args.verbose? || args.debug?
    @debug = args.debug?
    @offline = args.offline?

    count = Integer(args.count || DEFAULT_COUNT)
    odie "--count must be greater than 0" if count <= 0

    width = args.width ? Integer(args.width) : default_width
    odie "--width must be at least 80" if width < 80

    selections = selected_types(args)
    additions_by_type = preload_additions(selections, count)

    selections.each_with_index do |type, index|
      puts if index.positive?
      puts title_for(type)
      print_table_header(width)
      stream_items(type, additions_by_type.fetch(type), count, width)
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

  def preload_additions(selections, count)
    threads = selections.to_h do |type|
      [type, Thread.new { newest_candidates(type, count) }]
    end

    threads.transform_values(&:value)
  end

  def newest_candidates(type, count)
    trace "Collecting newest #{type}s"
    candidate_count = if @offline
      [count * 20, count + 100].max
    else
      [count * 4, count + 10].max
    end
    additions = local_additions(type, candidate_count)
    trace "Local #{type} additions found: #{additions.length}"
    if additions.length < count
      additions = remote_git_additions(type, candidate_count)
      trace "Remote git #{type} additions found: #{additions.length}"
    end
    if additions.length < count
      trace "Offline mode: skipping GitHub API fallback for #{type}" if @offline
    end
    if additions.length < count && !@offline
      additions = github_additions(type, candidate_count)
      trace "GitHub API #{type} additions found: #{additions.length}"
    end
    if additions.empty?
      if @offline
        odie "Unable to determine newest #{type}s in offline mode. Install local #{type == :formula ? 'homebrew/core' : 'homebrew/cask'} tap history or run without --offline."
      end

      odie "Unable to determine newest #{type}s."
    end

    sort_additions_by_date(additions)
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

          results << { token: token, date: date[0, 10] }
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

    if @offline
      unless Dir.exist?(repo)
        trace "Offline mode: no stored remote git cache for #{type} at #{repo}"
        return []
      end

      trace "Offline mode: using stored remote git cache for #{type}"
      return remote_git_log(repo, type, count)
    end

    unless Dir.exist?(repo)
      trace "Cloning shallow remote cache into #{repo}"
      stdout, stderr, status = run_command(
        "git", "clone", "--bare", "--filter=blob:none", "--single-branch", "--branch", "main",
        "--no-tags", "--depth=#{INITIAL_REMOTE_DEPTH}", remote, repo
      )
      return [] unless status.success?
    end

    trace "Refreshing remote git cache for #{type}"
    stdout, stderr, status = run_command(
      "git", "-C", repo, "fetch", "--force", "--filter=blob:none", "--no-tags",
      "--update-shallow", "--depth=#{INITIAL_REMOTE_DEPTH}", "origin", "main"
    )
    return [] unless status.success?

    results = remote_git_log(repo, type, count)
    deepen_attempts = 0

    while results.length < count && deepen_attempts < MAX_REMOTE_DEEPENS
      trace "Deepening remote git cache for #{type} (attempt #{deepen_attempts + 1})"
      stdout, stderr, status = run_command(
        "git", "-C", repo, "fetch", "--deepen=#{REMOTE_DEEPEN_STEP}", "--filter=blob:none",
        "--no-tags", "origin", "main"
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

  def stream_items(type, additions, count, width)
    mutex = Mutex.new
    printed = 0
    found_any = false
    next_index = 0
    pending = {}
    stop = false
    unresolved = []

    additions.each_with_index do |entry, index|
      cached = cached_metadata_entry(type, entry[:token])
      if cached.nil?
        unresolved << [index, entry]
        next
      end

      pending[index] = build_item(entry, cached)
    end

    printed, found_any, next_index, stop = flush_pending_rows(
      pending, next_index, printed, count, width, found_any
    )

    cursor = 0

    workers = Array.new([INFO_WORKERS, unresolved.length].min) do
      Thread.new do
        loop do
          batch = mutex.synchronize do
            if stop || cursor >= unresolved.length
              nil
            else
              slice = unresolved[cursor, INFO_BATCH_SIZE]
              cursor += INFO_BATCH_SIZE
              slice
            end
          end
          break if batch.nil?

          infos = fetch_metadata_batch(type, batch.map { |_, entry| entry[:token] })

          mutex.synchronize do
            next if stop

            batch.each do |index, entry|
              info = infos[entry[:token]]
              pending[index] = info.nil? ? nil : build_item(entry, info)
            end

            printed, found_any, next_index, stop = flush_pending_rows(
              pending, next_index, printed, count, width, found_any
            )
          end
        end
      end
    end

    workers.each(&:join)
    odie "Unable to find available newest #{type}s." unless found_any
  end

  def fetch_metadata_batch(type, names)
    return {} if names.empty?
    return fetch_metadata_batch_uncached(type, names)
  end

  def fetch_metadata_batch_uncached(type, names)
    if @offline
      trace "Offline mode: skipping uncached metadata fetch for #{type} (#{names.length})"
      return {}
    end

    flag = type == :formula ? "--formula" : "--cask"
    trace "Fetching metadata batch for #{type} (#{names.length}): #{names.join(', ')}"
    stdout, stderr, status = run_command(brew_binary, "info", "--json=v2", flag, *names)
    return parse_metadata_collection(type, stdout) if status.success?

    return {} if names.length == 1

    midpoint = names.length / 2
    left = fetch_metadata_batch_uncached(type, names[0...midpoint])
    right = fetch_metadata_batch_uncached(type, names[midpoint..])
    left.merge(right)
  rescue JSON::ParserError => e
    odie "Failed to parse metadata for newest #{type}s: #{e.message}"
  end

  def build_item(entry, info)
    Item.new(
      name:     info.fetch(:name),
      date:     entry.fetch(:date),
      homepage: info.fetch(:homepage),
      desc:     info.fetch(:desc),
    )
  end

  def cached_metadata_entry(type, name)
    path = cached_metadata_path(type, name)
    if File.exist?(path)
      debug "Using cached metadata for #{type}: #{name}"
      return parse_metadata_json(type, File.read(path))
    end

    aggregate_cached_metadata_entry(type, name)
  rescue Errno::ENOENT, JSON::ParserError
    nil
  end

  def aggregate_cached_metadata_entry(type, name)
    cache = aggregate_metadata_cache(type)
    entry = cache[name]
    return nil if entry.nil?

    debug "Using aggregate cached metadata for #{type}: #{name}"
    entry
  end

  def aggregate_metadata_cache(type)
    @aggregate_metadata_cache ||= {}
    @aggregate_metadata_cache[type] ||= begin
      path = aggregate_cached_metadata_path(type)
      if File.exist?(path)
        raw = JSON.parse(File.read(path))
        payload = raw["payload"]

        if payload.nil?
          {}
        else
          entries = JSON.parse(payload)
          entries.each_with_object({}) do |entry, map|
            token = type == :formula ? entry.fetch("name") : entry.fetch("token")
            map[token] = metadata_hash(type, entry)
          end
        end
      else
        {}
      end
    rescue Errno::ENOENT, JSON::ParserError
      {}
    end
  end

  def parse_metadata_collection(type, json_text)
    json = JSON.parse(json_text)
    key = type == :formula ? "formulae" : "casks"
    Array(json[key]).each_with_object({}) do |entry, map|
      token = type == :formula ? entry.fetch("name") : entry.fetch("token")
      map[token] = metadata_hash(type, entry)
    end
  end

  def parse_metadata_json(type, json_text)
    json = JSON.parse(json_text)
    key = type == :formula ? "formulae" : "casks"
    entry = if json.is_a?(Hash) && json.key?(key)
      Array(json[key]).first
    else
      json
    end
    return nil if entry.nil?

    metadata_hash(type, entry)
  end

  def print_table_header(width)
    widths = column_widths(width)
    puts row("Name", "Date", "Homepage", "Description", *widths)
    puts row("-" * widths[0], "-" * widths[1], "-" * widths[2], "-" * widths[3], *widths)
  end

  def format_item_row(item, width)
    widths = column_widths(width)
    row(
      truncate(item.name, widths[0]),
      item.date,
      format_cell(item.homepage, widths[2]),
      format_cell(item.desc, widths[3]),
      *widths,
    )
  end

  def column_widths(width)
    name_width = 24
    date_width = 10
    separator = "  "
    fixed = name_width + date_width + (separator.length * 3)
    remaining = [width - fixed, 40].max
    home_width = [[remaining / 2, 32].max, 56].min
    desc_width = [remaining - home_width, 24].max
    [name_width, date_width, home_width, desc_width]
  end

  def flush_pending_rows(pending, next_index, printed, count, width, found_any)
    while pending.key?(next_index) && printed < count
      ready_item = pending.delete(next_index)
      next_index += 1
      next if ready_item.nil?

      puts format_item_row(ready_item, width)
      $stdout.flush
      found_any = true
      printed += 1
    end

    [printed, found_any, next_index, printed >= count]
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

  def format_cell(text, width)
    value = text.to_s.gsub(/\s+/, " ").strip
    return value if @verbose

    truncate(value, width)
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

      results << { token: token, date: current_date }
      break if results.length >= count
    end

    results
  end

  def sort_additions_by_date(additions)
    additions.sort_by do |entry|
      [entry[:date].to_s.empty? ? 1 : 0, entry[:date].to_s.empty? ? "" : -entry[:date].delete("-").to_i]
    end
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

  def cached_metadata_path(type, name)
    dir = type == :formula ? "formula" : "cask"
    File.expand_path("~/Library/Caches/Homebrew/api/#{dir}/#{name}.json")
  end

  def aggregate_cached_metadata_path(type)
    name = type == :formula ? "formula.jws.json" : "cask.jws.json"
    File.expand_path("~/Library/Caches/Homebrew/api/#{name}")
  end

  def metadata_hash(type, entry)
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
