# frozen_string_literal: true

# Minimal Minitest-compatible shim for environments where the minitest gem
# is unavailable (e.g. Homebrew portable-ruby 4.0+).

module Minitest
  class Test
    def self.inherited(subclass)
      (@subclasses ||= []) << subclass
    end

    def self.subclasses
      @subclasses || []
    end

    def self.run_all
      passed = 0
      failed = 0
      errors = 0

      Minitest::Test.subclasses.each do |klass|
        instance = klass.new
        test_methods = klass.instance_methods(false).select { |m| m.to_s.start_with?("test_") }
        test_methods.each do |method|
          instance.setup if instance.respond_to?(:setup)
          instance.send(method)
          passed += 1
          print "."
        rescue Minitest::Assertion => e
          failed += 1
          print "F"
          $stderr.puts "\nFAIL: #{klass}##{method}: #{e.message}"
        rescue => e
          errors += 1
          print "E"
          $stderr.puts "\nERROR: #{klass}##{method}: #{e.class}: #{e.message}"
          $stderr.puts e.backtrace.first(5).map { |l| "  #{l}" }.join("\n")
        end
      end

      puts
      total = passed + failed + errors
      puts "#{total} tests, #{failed} failures, #{errors} errors"
      exit(1) if failed > 0 || errors > 0
    end

    class Assertion < RuntimeError; end

    private

    def assert(value, msg = nil)
      return if value

      raise Assertion, msg || "Expected truthy, got #{value.inspect}"
    end

    def refute(value, msg = nil)
      return unless value

      raise Assertion, msg || "Expected falsey, got #{value.inspect}"
    end

    def assert_equal(expected, actual, msg = nil)
      return if expected == actual

      raise Assertion, msg || "Expected #{expected.inspect}, got #{actual.inspect}"
    end

    def assert_includes(collection, item, msg = nil)
      return if collection.include?(item)

      raise Assertion, msg || "Expected #{collection.inspect} to include #{item.inspect}"
    end

    def capture_io
      old_stdout = $stdout
      old_stderr = $stderr
      $stdout = StringIO.new
      $stderr = StringIO.new
      yield
      [$stdout.string, $stderr.string]
    ensure
      $stdout = old_stdout
      $stderr = old_stderr
    end
  end
end
