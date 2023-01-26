# frozen_string_literal: true
require_relative "../command"
require_relative "../package"
require_relative "../version_option"

class Gem::Commands::ExecCommand < Gem::Command
  include Gem::VersionOption

  def initialize
    super "exec", "Run a command from a gem", {
      version: Gem::Requirement.default,
    }

    add_platform_option
    add_version_option
    add_prerelease_option "to be installed"

    add_option "-g", "--gem GEM", "run the executable from the given gem" do |value, options|
      options[:gem_name] = value
    end

    add_option(:"Install/Update", "--conservative",
      "Prefer the most recent installed version, ",
      "rather than the latest version overall") do |value, options|
      options[:conservative] = true
    end
  end

  def arguments # :nodoc:
    "COMMAND  the executable command to run"
  end

  def defaults_str # :nodoc:
    "--version '#{Gem::Requirement.default}'"
  end

  def description # :nodoc:
    <<-EOF
    EOF
  end

  def usage # :nodoc:
    "#{program_name} [options --] COMMAND [args]"
  end

  def execute
    check_executable

    print_command
    if options[:conservative]
      install_if_needed
    else
      install
      activate!
    end

    load!
  end

  private

  def handle_options(args)
    args = add_extra_args(args)
    check_deprecated_options(args)
    @options = Marshal.load Marshal.dump @defaults # deep copy
    parser.order!(args) do |v|
      # put the non-option back at the front of the list of arguments
      args.unshift(v)

      # stop parsing once we hit the first non-option,
      # so you can call `gem exec rails --version` and it prints the rails
      # version rather than rubygem's
      break
    end
    @options[:args] = args

    options[:executable], gem_version = extract_gem_name_and_version(options[:args].shift)
    options[:gem_name] ||= options[:executable]
    options[:version] = gem_version if gem_version
  end

  def check_executable
    if options[:executable].nil?
      raise Gem::CommandLineError,
        "Please specify an executable to run (e.g. #{program_name} COMMAND)"
    end
  end

  def print_command
    verbose "running #{program_name} with:\n"
    opts = options.reject {|_, v| v.nil? || Array(v).empty? }
    max_length = opts.map {|k, _| k.size }.max
    opts.each do |k, v|
      next if v.nil?
      verbose "\t#{k.to_s.rjust(max_length)}: #{v} "
    end
    verbose ""
  end

  def install_if_needed
    activate!
  rescue Gem::MissingSpecError
    verbose "#{dependency_to_s} not available locally"
    install
    activate!
  end

  def install
    gem_name = options[:gem_name]
    gem_version = options[:version]

    home = Gem.paths.home
    home = File.join(home, "gem_exec")
    Gem.use_paths(home, Gem.path + [home])

    suppress_always_install do
      Gem.install(gem_name, gem_version)
    end
  rescue Gem::InstallError => e
    alert_error "Error installing #{gem_name}:\n\t#{e.message}"
    terminate_interaction 1
  rescue Gem::GemNotFoundException => e
    show_lookup_failure e.name, e.version, e.errors, false

    terminate_interaction 2
  rescue Gem::UnsatisfiableDependencyError => e
    show_lookup_failure e.name, e.version, e.errors, false,
                        "'#{gem_name}' (#{gem_version})"

    terminate_interaction 2
  end

  def activate!
    gem(options[:gem_name], options[:version])
    Gem.finish_resolve
  end

  def load!
    argv = ARGV.clone
    ARGV.replace options[:args]

    exe = executable = options[:executable]

    contains_executable = Gem.loaded_specs.values.select do |spec|
      spec.executables.include?(executable)
    end

    if contains_executable.any? {|s| s.name == executable }
      contains_executable.select! {|s| s.name == executable }
    end

    if contains_executable.empty?
      if (spec = Gem.loaded_specs[executable]) && (exe = spec.executable)
        contains_executable << spec
      else
        alert_error "Failed to load executable `#{executable}`," \
              " are you sure the gem `#{options[:gem_name]}` contains it?"
        terminate_interaction 1
      end
    end

    if contains_executable.size > 1
      alert_error "Ambiguous which gem `#{executable}` should come from: " \
            "the options are #{contains_executable.map(&:name)}, " \
            "specify one via `-g`"
      terminate_interaction 1
    end

    load Gem.activate_bin_path(contains_executable.first.name, exe, ">= 0.a")
  ensure
    ARGV.replace argv
  end

  def suppress_always_install
    name = :always_install
    cls = ::Gem::Resolver::InstallerSet
    method = cls.instance_method(name)
    cls.define_method(name) { [] }

    begin
      yield
    ensure
      cls.define_method(name, method)
    end
  end
end