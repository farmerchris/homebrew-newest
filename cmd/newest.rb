# typed: strict
# frozen_string_literal: true

require "abstract_command"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

module Homebrew
  module Cmd
    # List newly added formulae and casks.
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
        comma_array "--tap=",
                    description: "Restrict results to the specified tap or comma-separated taps."
        flag "-n", "--count=",
             description: "Number of entries to show for each selected type."
        flag "--width=",
             description: "Target table width. Defaults to $COLUMNS or 140."
      end

      def run
        BrewNewest.new.run(args)
      end
    end

    # Internal implementation for the `brew newest` command.
    class BrewNewest
      include Utils::Output::Mixin

      DEFAULT_WIDTH = 140
      DEFAULT_COUNT = 10
      INITIAL_REMOTE_DEPTH = 200
      REMOTE_DEEPEN_STEP = 200
      MAX_REMOTE_DEPTH = 2000
      LOCAL_SCAN_WORKERS = 4
      INFO_WORKERS = 3
      INFO_BATCH_SIZE = 8
      DATE_MARKER = "__BREW_NEWEST_DATE__"
      COMMIT_MARKER = "__BREW_NEWEST_COMMIT__"
      Item = Struct.new(:name, :date, :homepage, :desc)

      def run(args)
        @verbose = args.verbose? || args.debug?
        @debug = args.debug?
        @offline = args.offline?
        @selected_taps = normalize_selected_taps(args.tap)
        @cache_mutex = Mutex.new
        @tap_repo_paths = {}
        @shallow_boundary_cache = {}

        count = Integer(args.count || DEFAULT_COUNT)
        odie "--count must be greater than 0" if count <= 0

        width = args.width ? Integer(args.width) : default_width
        odie "--width must be at least 80" if width < 80

        selections = selected_types(args)
        prime_shared_state(selections)
        additions_by_type = preload_additions(selections, count)
        available_types = selections.select { |type| additions_by_type.fetch(type).any? }

        odie "No matching formulae or casks found for the selected taps." if available_types.empty?

        available_types.each_with_index do |type, index|
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
        selected = [:formula, :cask] if selected.empty?
        selected
      end

      def preload_additions(selections, count)
        threads = selections.to_h do |type|
          [type, Thread.new { newest_candidates(type, count) }]
        end

        threads.transform_values(&:value)
      end

      def prime_shared_state(selections)
        taps = selections.flat_map { |type| installed_taps(type) }.uniq
        taps.each { |tap| tap_repo_path(tap) }
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
        if official_fallback_allowed?(type)
          additions = dedupe_additions(additions + remote_git_additions(type, candidate_count))
          trace "Remote git #{type} additions found: #{additions.length}"
        end
        if additions.empty?
          return [] if @selected_taps&.any?

          if @offline
            tap_name = (type == :formula) ? "homebrew/core" : "homebrew/cask"
            odie "Unable to determine newest #{type}s in offline mode. " \
                 "Install local #{tap_name} tap history or run without --offline."
          end

          odie "Unable to determine newest #{type}s."
        end

        sort_additions_by_date(additions)
      end

      def local_additions(type, count)
        taps = installed_taps(type)
        cursor = 0
        mutex = Mutex.new
        results = []

        workers = Array.new([LOCAL_SCAN_WORKERS, taps.length].min) do
          Thread.new do
            local_results = []

            loop do
              tap = mutex.synchronize do
                next if cursor >= taps.length

                current_tap = taps[cursor]
                cursor += 1
                current_tap
              end
              break if tap.nil?

              repo = tap_repo_path(tap)
              trace "Checking local #{type} repo for #{tap}: #{repo.inspect}"
              next if !repo || !File.directory?(repo)

              scope = (type == :formula) ? "Formula" : "Casks"
              next unless File.directory?(File.join(repo, scope))

              stdout, _, status = run_command(
                "git", "-C", repo, "log", "--diff-filter=ARC", "--name-status",
                "--format=#{COMMIT_MARKER}%H%n#{DATE_MARKER}%aI", "--", scope
              )
              next unless status.success?

              local_results.concat(parse_git_log(stdout, type, count, tap, repo))
            end

            mutex.synchronize { results.concat(local_results) }
          end
        end

        workers.each(&:join)

        dedupe_additions(results)
      rescue Errno::ENOENT
        []
      end

      def remote_git_additions(type, count)
        return [] unless official_fallback_allowed?(type)

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
          _, _, status = run_command(
            "git", "clone", "--bare", "--filter=blob:none", "--single-branch", "--branch", "main",
            "--no-tags", "--depth=#{INITIAL_REMOTE_DEPTH}", remote, repo
          )
          return [] unless status.success?
        end

        trace "Refreshing remote git cache for #{type}"
        _, _, status = run_command(
          "git", "-C", repo, "fetch", "--force", "--filter=blob:none", "--no-tags",
          "origin", "main"
        )
        return [] unless status.success?

        results = remote_git_log(repo, type, count)
        current_depth = INITIAL_REMOTE_DEPTH

        while results.length < count && current_depth < MAX_REMOTE_DEPTH
          next_depth = [current_depth + REMOTE_DEEPEN_STEP, MAX_REMOTE_DEPTH].min
          trace "Deepening remote git cache for #{type} to depth #{next_depth}"
          _, _, status = run_command(
            "git", "-C", repo, "fetch", "--deepen=#{REMOTE_DEEPEN_STEP}", "--filter=blob:none",
            "--no-tags", "origin", "main"
          )
          break unless status.success?

          results = remote_git_log(repo, type, count)
          current_depth = next_depth
        end

        results
      rescue Errno::ENOENT
        []
      end

      def remote_git_log(repo, type, count)
        scope = (type == :formula) ? "Formula" : "Casks"
        stdout, _, status = run_command(
          "git", "-C", repo, "log", "--diff-filter=ARC", "--name-status",
          "--format=#{COMMIT_MARKER}%H%n#{DATE_MARKER}%aI", "--", scope
        )
        return [] unless status.success?

        parse_git_log(stdout, type, count, nil, repo)
      end

      def stream_items(type, additions, count, width)
        return stream_items_offline(type, additions, count, width) if @offline

        mutex = Mutex.new
        printed = 0
        found_any = false
        next_index = 0
        pending = {}
        unresolved = []

        additions.each_with_index do |entry, index|
          cached = cached_metadata_entry(type, entry[:query])
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

              infos = fetch_metadata_batch(type, batch.map { |_, entry| entry[:query] })

              mutex.synchronize do
                next if stop

                batch.each do |index, entry|
                  info = infos[entry[:query]]
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

      def stream_items_offline(type, additions, count, width)
        printed = 0

        additions.each do |entry|
          cached = cached_metadata_entry(type, entry[:query])
          next if cached.nil?

          puts format_item_row(build_item(entry, cached), width)
          printed += 1
          break if printed >= count
        end

        odie "Unable to find available newest #{type}s." if printed.zero?
      end

      def fetch_metadata_batch(type, names)
        return {} if names.empty?

        fetch_metadata_batch_uncached(type, names)
      end

      def fetch_metadata_batch_uncached(type, names)
        if @offline
          trace "Offline mode: skipping uncached metadata fetch for #{type} (#{names.length})"
          return {}
        end

        flag = (type == :formula) ? "--formula" : "--cask"
        trace "Fetching metadata batch for #{type} (#{names.length}): #{names.join(", ")}"
        stdout, _, status = run_command(brew_binary, "info", "--json=v2", flag, *names)
        return parse_metadata_collection(type, stdout) if status.success?

        if names.length == 1
          fallback = fallback_query_name(names.first)
          if fallback && fallback != names.first
            trace "Retrying metadata lookup for #{type} with fallback query: #{fallback}"
            stdout, _, status = run_command(brew_binary, "info", "--json=v2", flag, fallback)
            return parse_metadata_collection(type, stdout) if status.success?
          end

          return {}
        end

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

      def cached_metadata_entry(type, query)
        path = cached_metadata_path(type, query)
        if File.exist?(path)
          debug "Using cached metadata for #{type}: #{query}"
          return parse_metadata_json(type, File.read(path))
        end

        aggregate_cached_metadata_entry(type, query)
      rescue Errno::ENOENT, JSON::ParserError
        nil
      end

      def aggregate_cached_metadata_entry(type, query)
        cache = aggregate_metadata_cache(type)
        entry = cache[query]
        return if entry.nil?

        debug "Using aggregate cached metadata for #{type}: #{query}"
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
                index_metadata_entry(type, entry, map)
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
        key = (type == :formula) ? "formulae" : "casks"
        Array(json[key]).each_with_object({}) do |entry, map|
          index_metadata_entry(type, entry, map)
        end
      end

      def parse_metadata_json(type, json_text)
        json = JSON.parse(json_text)
        key = (type == :formula) ? "formulae" : "casks"
        entry = if json.is_a?(Hash) && json.key?(key)
          Array(json[key]).first
        else
          json
        end
        return if entry.nil?

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
        name_width = 30
        date_width = 10
        separator = "  "
        fixed = name_width + date_width + (separator.length * 3)
        remaining = [width - fixed, 40].max
        home_width = (remaining / 2).clamp(32, 56)
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

      def parse_git_log(stdout, type, count, tap = nil, repo = nil)
        current_date = nil
        current_commit = nil
        results = []
        shallow_boundaries = shallow_boundary_commits(repo)

        stdout.each_line do |line|
          line = line.chomp
          next if line.empty?

          if line.start_with?(COMMIT_MARKER)
            current_commit = line.delete_prefix(COMMIT_MARKER)
            next
          end

          if line.start_with?(DATE_MARKER)
            current_date = line.delete_prefix(DATE_MARKER)[0, 10]
            next
          end

          next if current_commit && shallow_boundaries.include?(current_commit)

          status, path = parse_name_status_line(line)
          next unless %w[A R C].include?(status)

          token = token_from_path(path)
          next if token.nil?
          next unless path_matches_type?(path, type)

          query = tap_query_name(tap, type, token)
          next if results.any? { |entry| entry[:query] == query }

          results << { token: token, query: query, date: current_date }
          break if results.length >= count
        end

        results
      end

      def shallow_boundary_commits(repo)
        return Set.new if repo.blank?

        @cache_mutex.synchronize do
          @shallow_boundary_cache.fetch(repo) do
            @shallow_boundary_cache[repo] = load_shallow_boundary_commits(repo)
          end
        end
      end

      def sort_additions_by_date(additions)
        additions.sort_by do |entry|
          [entry[:date].to_s.empty? ? 1 : 0, entry[:date].to_s.empty? ? "" : -entry[:date].delete("-").to_i]
        end
      end

      def token_from_path(path)
        return unless path.end_with?(".rb")

        File.basename(path, ".rb")
      end

      def parse_name_status_line(line)
        fields = line.split("\t")
        return if fields.empty?

        status = fields.first[0]
        path = case status
        when "A"
          fields[1]
        when "R", "C"
          fields[2]
        end
        return if path.blank?

        [status, path]
      end

      def tap_query_name(tap, type, token)
        return token if tap.nil?
        return token if type == :formula && tap.casecmp("homebrew/core").zero?
        return token if type == :cask && tap.casecmp("homebrew/cask").zero?

        "#{tap}/#{token}"
      end

      def dedupe_additions(additions)
        additions.each_with_object([]) do |entry, unique|
          next if unique.any? { |candidate| candidate[:query] == entry[:query] }

          unique << entry
        end
      end

      def path_matches_type?(path, type)
        if type == :formula
          path.start_with?("Formula/")
        else
          path.start_with?("Casks/")
        end
      end

      def tap_repo_path(tap)
        @cache_mutex.synchronize do
          @tap_repo_paths.fetch(tap) do
            @tap_repo_paths[tap] = load_tap_repo_path(tap)
          end
        end
      end

      def installed_taps(type)
        taps = if @selected_taps&.any?
          @selected_taps.dup
        else
          all = brew_taps
          all << "homebrew/core" if type == :formula
          all << "homebrew/cask" if type == :cask
          all.uniq
        end

        taps.select { |tap| tap_supports_type?(tap, type) }
      end

      def brew_taps
        @cache_mutex.synchronize do
          @brew_taps ||= begin
            stdout, _, status = run_command(brew_binary, "tap")
            status.success? ? stdout.lines.map(&:strip).reject(&:empty?) : []
          end
        end
      end

      def normalize_selected_taps(taps)
        return if taps.blank?

        taps.map(&:strip).reject(&:empty?).uniq
      end

      def tap_supports_type?(tap, type)
        return true if type == :formula

        tap.casecmp("homebrew/core").nonzero?
      end

      def official_fallback_allowed?(type)
        return true if @selected_taps.blank?

        target = (type == :formula) ? "homebrew/core" : "homebrew/cask"
        @selected_taps.any? { |tap| tap.casecmp(target).zero? }
      end

      def remote_git_url(type)
        (type == :formula) ? "https://github.com/Homebrew/homebrew-core.git" : "https://github.com/Homebrew/homebrew-cask.git"
      end

      def remote_cache_path(type)
        File.join(Dir.tmpdir, "brew-newest-cache", "#{type}.git")
      end

      def cached_metadata_path(type, query)
        dir = (type == :formula) ? "formula" : "cask"
        token = query.to_s.split("/").last
        File.expand_path("~/Library/Caches/Homebrew/api/#{dir}/#{token}.json")
      end

      def aggregate_cached_metadata_path(type)
        name = (type == :formula) ? "formula.jws.json" : "cask.jws.json"
        File.expand_path("~/Library/Caches/Homebrew/api/#{name}")
      end

      def metadata_hash(type, entry)
        token = (type == :formula) ? entry.fetch("name") : entry.fetch("token")
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

      def index_metadata_entry(type, entry, map)
        token = (type == :formula) ? entry.fetch("name") : entry.fetch("token")
        full_name = (type == :formula) ? entry.fetch("full_name", token) : entry.fetch("full_token", token)
        metadata = metadata_hash(type, entry)

        map[token] = metadata
        map[full_name] = metadata
      end

      def fallback_query_name(query)
        return unless query.include?("/")

        query.split("/").last
      end

      def brew_binary
        ENV["HOMEBREW_BREW_FILE"] || "brew"
      end

      def title_for(type)
        (type == :formula) ? "Newest Formulae" : "Newest Casks"
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
        debug "Running: #{command.join(" ")}"
        stdout, stderr, status = Open3.capture3(*command)
        debug "Exit #{status.exitstatus}: #{stderr.strip}" if @debug && !status.success? && !stderr.to_s.strip.empty?
        [stdout, stderr, status]
      end

      def load_shallow_boundary_commits(repo)
        git_dir = git_dir_path(repo)
        return Set.new if git_dir.nil?

        shallow_path = File.join(git_dir, "shallow")
        return Set.new unless File.exist?(shallow_path)

        Set.new(File.readlines(shallow_path, chomp: true).reject(&:empty?))
      rescue Errno::ENOENT
        Set.new
      end

      def git_dir_path(repo)
        dot_git = File.join(repo, ".git")
        return dot_git if File.directory?(dot_git)

        if File.file?(dot_git)
          gitdir = File.read(dot_git)[/\Agitdir: (.+)\n?\z/, 1]
          return if gitdir.nil?

          return File.expand_path(gitdir, repo)
        end

        return repo if File.directory?(File.join(repo, "objects")) && File.directory?(File.join(repo, "refs"))

        nil
      rescue Errno::ENOENT
        nil
      end

      def load_tap_repo_path(tap)
        stdout, _, status = run_command(brew_binary, "--repo", tap)
        return unless status.success?

        stdout.strip
      rescue Errno::ENOENT
        nil
      end
    end
  end
end

Homebrew::Cmd::Newest.new.run if $PROGRAM_NAME == __FILE__
