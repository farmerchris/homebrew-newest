begin
  require "minitest/autorun"
rescue LoadError
  require "stringio"
  require_relative "minitest_shim"
end
require_relative "../cmd/newest"

class BrewNewestTest < Minitest::Test
  def setup
    @subject = Homebrew::Cmd::BrewNewest.allocate
    @subject.instance_variable_set(:@cache_mutex, Mutex.new)
    @subject.instance_variable_set(:@tap_repo_paths, {})
    @subject.instance_variable_set(:@shallow_boundary_cache, {})
    @subject.instance_variable_set(:@selected_taps, nil)
    @subject.instance_variable_set(:@all_taps, false)
    @subject.instance_variable_set(:@force_remote, false)
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

    @subject.define_singleton_method(:tap_repo_path) { |_tap| nil }

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

  def test_newest_candidates_uses_installed_official_tap_instead_of_remote_cache
    @subject.instance_variable_set(:@selected_taps, nil)
    @subject.instance_variable_set(:@all_taps, false)

    scan_single_tap_called = false
    remote_git_additions_called = false

    @subject.define_singleton_method(:tap_repo_path) { |_tap| Dir.tmpdir }
    @subject.define_singleton_method(:scan_single_tap) do |_tap, _type, _count|
      scan_single_tap_called = true
      [{ token: "local-formula", query: "local-formula", date: "2026-03-31" }]
    end
    @subject.define_singleton_method(:remote_git_additions) do |_type, _count|
      remote_git_additions_called = true
      []
    end

    results = @subject.send(:newest_candidates, :formula, 5)

    assert scan_single_tap_called, "should have scanned the installed official tap"
    refute remote_git_additions_called, "should not have used remote cache when official tap is installed"
    assert_equal ["local-formula"], results.map { |e| e[:query] }
  end

  def test_newest_candidates_falls_back_to_remote_cache_when_official_tap_not_installed
    @subject.instance_variable_set(:@selected_taps, nil)
    @subject.instance_variable_set(:@all_taps, false)

    remote_git_additions_called = false

    @subject.define_singleton_method(:tap_repo_path) { |_tap| nil }
    @subject.define_singleton_method(:remote_git_additions) do |_type, _count|
      remote_git_additions_called = true
      [{ token: "remote-formula", query: "remote-formula", date: "2026-03-30" }]
    end

    results = @subject.send(:newest_candidates, :formula, 5)

    assert remote_git_additions_called, "should have used remote cache when official tap is not installed"
    assert_equal ["remote-formula"], results.map { |e| e[:query] }
  end

  def test_force_homebrew_api_skips_installed_official_tap
    @subject.instance_variable_set(:@selected_taps, nil)
    @subject.instance_variable_set(:@all_taps, false)
    @subject.instance_variable_set(:@force_remote, true)

    scan_single_tap_called = false

    @subject.define_singleton_method(:tap_repo_path) { |_tap| Dir.tmpdir }
    @subject.define_singleton_method(:scan_single_tap) do |_tap, _type, _count|
      scan_single_tap_called = true
      []
    end
    @subject.define_singleton_method(:remote_git_additions) do |_type, _count|
      [{ token: "remote-formula", query: "remote-formula", date: "2026-03-30" }]
    end

    results = @subject.send(:newest_candidates, :formula, 5)

    refute scan_single_tap_called, "should not scan local tap when --force-homebrew-api is set"
    assert_equal ["remote-formula"], results.map { |e| e[:query] }
  end
end

Minitest::Test.run_all if Minitest::Test.respond_to?(:run_all)
