require "minitest/autorun"
require_relative "../cmd/newest"

class BrewNewestTest < Minitest::Test
  def setup
    @subject = Homebrew::Cmd::BrewNewest.allocate
    @subject.instance_variable_set(:@cache_mutex, Mutex.new)
    @subject.instance_variable_set(:@tap_repo_paths, {})
    @subject.instance_variable_set(:@shallow_boundary_cache, {})
    @subject.instance_variable_set(:@selected_taps, nil)
    @subject.instance_variable_set(:@all_taps, false)
    @subject.instance_variable_set(:@offline, false)
  end

  def test_parse_git_log_accepts_add_rename_and_copy_using_destination_path
    stdout = <<~EOS
      __BREW_NEWEST_COMMIT__aaa111
      __BREW_NEWEST_DATE__2026-03-31T10:00:00Z
      A\tFormula/plain.rb
      R100\tFormula/old-name.rb\tFormula/renamed.rb
      C100\tFormula/source.rb\tFormula/copied.rb
    EOS

    results = @subject.send(:parse_git_log, stdout, :formula, 10, "farmerchris/tap", "/tmp/repo")

    assert_equal(
      [
        { token: "plain", query: "farmerchris/tap/plain", date: "2026-03-31" },
        { token: "renamed", query: "farmerchris/tap/renamed", date: "2026-03-31" },
        { token: "copied", query: "farmerchris/tap/copied", date: "2026-03-31" },
      ],
      results,
    )
  end

  def test_parse_git_log_skips_shallow_boundary_commits
    stdout = <<~EOS
      __BREW_NEWEST_COMMIT__boundarysha
      __BREW_NEWEST_DATE__2026-03-31T10:00:00Z
      A\tFormula/old.rb
      __BREW_NEWEST_COMMIT__realsha
      __BREW_NEWEST_DATE__2026-03-30T10:00:00Z
      A\tFormula/new.rb
    EOS

    @subject.instance_variable_get(:@shallow_boundary_cache)["/tmp/repo"] = Set["boundarysha"]

    results = @subject.send(:parse_git_log, stdout, :formula, 10, "farmerchris/tap", "/tmp/repo")

    assert_equal([{ token: "new", query: "farmerchris/tap/new", date: "2026-03-30" }], results)
  end

  def test_parse_git_log_filters_type_and_dedupes_queries
    stdout = <<~EOS
      __BREW_NEWEST_COMMIT__aaa111
      __BREW_NEWEST_DATE__2026-03-31T10:00:00Z
      A\tFormula/demo.rb
      A\tFormula/demo.rb
      A\tCasks/not-a-formula.rb
    EOS

    results = @subject.send(:parse_git_log, stdout, :formula, 10, "farmerchris/tap", "/tmp/repo")

    assert_equal([{ token: "demo", query: "farmerchris/tap/demo", date: "2026-03-31" }], results)
  end

  def test_tap_selection_modes
    @subject.instance_variable_set(:@selected_taps, nil)
    @subject.instance_variable_set(:@all_taps, false)
    refute @subject.send(:scan_local_taps?)
    assert @subject.send(:use_official_cache?)

    @subject.instance_variable_set(:@selected_taps, ["farmerchris/tap"])
    refute @subject.send(:use_official_cache?)
    assert @subject.send(:scan_local_taps?)

    @subject.instance_variable_set(:@selected_taps, nil)
    @subject.instance_variable_set(:@all_taps, true)
    assert @subject.send(:scan_local_taps?)
    assert @subject.send(:use_official_cache?)
  end

  def test_newest_candidates_uses_both_local_and_official_sources_for_all_mode
    @subject.instance_variable_set(:@all_taps, true)

    def @subject.local_additions(_type, _count)
      [{ token: "local", query: "farmerchris/tap/local", date: "2026-03-31" }]
    end

    def @subject.remote_git_additions(_type, _count)
      [{ token: "official", query: "official", date: "2026-03-30" }]
    end

    results = @subject.send(:newest_candidates, :formula, 5)

    assert_equal(["farmerchris/tap/local", "official"], results.map { |entry| entry[:query] })
  end

  def test_remote_git_additions_fetches_into_local_main_ref_for_bare_cache
    commands = []
    @subject.define_singleton_method(:remote_cache_path) { |_type| "/tmp/remote.git" }
    @subject.define_singleton_method(:remote_git_log) do |_repo, _type, _count|
      [{ token: "demo", query: "demo", date: "2026-03-31" }]
    end
    @subject.define_singleton_method(:run_command) do |*command|
      commands << command
      ["", "", Object.new.tap { |status| status.define_singleton_method(:success?) { true } }]
    end

    @subject.send(:remote_git_additions, :formula, 1)

    assert_includes(
      commands,
      [
        "git", "-C", "/tmp/remote.git", "fetch", "--force", "--filter=blob:none", "--no-tags",
        "origin", "+refs/heads/main:refs/heads/main",
      ],
    )
  end

  def test_offline_local_tap_mode_uses_uncached_metadata_lookup
    @subject.instance_variable_set(:@selected_taps, ["farmerchris/tap"])
    @subject.instance_variable_set(:@offline, true)

    def @subject.cached_metadata_entry(_type, _query)
      nil
    end

    def @subject.fetch_metadata_batch_uncached(_type, names)
      {
        names.first => {
          name: "farmerchris/tap/demo",
          homepage: "https://example.com",
          desc: "Demo formula",
        },
      }
    end

    output = capture_io do
      @subject.send(
        :stream_items_offline,
        :formula,
        [{ token: "demo", query: "farmerchris/tap/demo", date: "2026-03-31" }],
        1,
        140,
      )
    end.first

    assert_includes output, "farmerchris/tap/demo"
    assert_includes output, "https://example.com"
    assert_includes output, "Demo formula"
  end

  def test_offline_local_tap_mode_falls_back_to_placeholder_metadata
    @subject.instance_variable_set(:@selected_taps, ["farmerchris/tap"])
    @subject.instance_variable_set(:@offline, true)

    def @subject.cached_metadata_entry(_type, _query)
      nil
    end

    def @subject.fetch_metadata_batch_uncached(_type, _names)
      {}
    end

    output = capture_io do
      @subject.send(
        :stream_items_offline,
        :formula,
        [{ token: "demo", query: "farmerchris/tap/demo", date: "2026-03-31" }],
        1,
        140,
      )
    end.first

    assert_includes output, "farmerchris/tap/demo"
    assert_includes output, "-"
  end
end
