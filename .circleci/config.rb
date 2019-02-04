require "yaml"

ruby_versions = {
  ruby_2_6: '2.6.0',
  ruby_2_5: '2.5.3',
  ruby_2_4: '2.4.5',
  ruby_2_3: '2.3.8',
}
rails_versions = {
  rails_5_2: '5.2.2',
  rails_5_1: '5.1.6.1',
  rails_5_0: '5.0.7',
  rails_4_2: '4.2.11',
}
GEMS = %w[
  aggregate_root
  bounded_context
  ruby_event_store
  ruby_event_store-browser
  ruby_event_store-rom
  rails_event_store
  rails_event_store_active_record
  rails_event_store-rspec
]
RAILS_GEMS = %w[
  bounded_context
  rails_event_store
  rails_event_store_active_record
  rails_event_store-rspec
]
RDBMS_GEMS = %w[
  rails_event_store_active_record
  ruby_event_store-rom
]
DATATYPE_GEMS = %w[
  ruby_event_store-rom
]

def Config(jobs, workflows)
  {
    "version" => "2.1",
    "jobs" => jobs,
    "workflows" => {
      "version" => "2"
    }.merge(workflows)
  }
end

def Run(command)
  { "run" => command }
end

def NamedRun(name, command)
  { "run" => { "name" => name, "command" => command } }
end

def Workflow(name, jobs)
  { name => { "jobs" => jobs } }
end

def Requires(dependencies)
  dependencies.flat_map do |dependent, required|
    [required, { dependent => { "requires" => Array(required) } }]
  end
end

def Docker(image, environment = {})
  docker = { "image" => image }
  docker = { "environment" => environment }.merge(docker) unless environment.empty?
  {
    "docker" => [
      docker,
      { "image" => "postgres:11", "environment" => %w(POSTGRES_DB=rails_event_store POSTGRES_PASSWORD=secret) },
      { "image" => "mysql:8", "environment" => %w(MYSQL_DATABASE=rails_event_store MYSQL_ROOT_PASSWORD=secret), "command" => "--default-authentication-plugin=mysql_native_password" }
    ]
  }
end

def Job(name, docker, steps)
  { name => docker.merge("steps" => steps) }
end

database_url =
  ->(gem_name) do
    case gem_name
    when /active_record/
      "sqlite3:db.sqlite3"
    when /rom/
      "sqlite:db.sqlite3"
    else
      "sqlite3::memory:"
    end
  end

merge = ->(array, transform = ->(item) { item }) do
  array.reduce({}) { |memo, item| memo.merge(transform.(item)) }
end

job = ->(task, env, name, gem_name) do
  env = {
    'RUBY_VERSION'  => ruby_versions[:ruby_2_6],
    'RAILS_VERSION' => rails_versions[:rails_5_2],
    'DATABASE_URL'  => database_url[gem_name],
    'DATA_TYPE'     => 'binary',
    'MUTANT_JOBS'   => 4
  }.merge(env)
  docker = Docker("pawelpacana/res:#{env['RUBY_VERSION']}", env)
  Job(name, docker, ["checkout", Run("make -C #{gem_name} install #{task}")])
end

job_name = ->(task, gem_name, version_name) do
  [task, gem_name, version_name]
    .map { |name| name.gsub("-", "_").gsub(".", "_") }
    .join('_')
end

check_config =
  Job(
    "check_config",
    Docker("pawelpacana/res:2.6.0"),
    [
      "checkout",
      NamedRun(
        "Verify .circleci/config.yml is generated from .circleci/config.rb",
        %Q[WAS="$(md5sum .circleci/config.yml)" && ruby .circleci/config.rb && test "$WAS" == "$(md5sum .circleci/config.yml)"]
      )
    ]
  )

rubies =
  merge[ruby_versions.to_a.product(GEMS).map { |(version_sym, version_number), gem_name|
    env = {
      "RUBY_VERSION" => version_number,
      "DATABASE_URL" => database_url[gem_name]
    }
    job['test', env, job_name['test', gem_name, version_sym.to_s], gem_name]
  }]
rails =
  merge[rails_versions.drop(1).to_a.product(RAILS_GEMS).map { |(version_sym, version_number), gem_name|
    env = {
      "RAILS_VERSION" => version_number,
      "RUBY_VERSION"  => ruby_versions[:ruby_2_5],
      "DATABASE_URL"  => database_url[gem_name]
    }
    job['test', env, job_name['test', gem_name, version_sym.to_s], gem_name]
  }]
mutations =
  merge[GEMS, ->(gem_name) {
    job['mutate', {}, job_name['mutate', gem_name, 'ruby_2_6'], gem_name]
  }]
mysql_compat =
  merge[RDBMS_GEMS, ->(gem_name) {
    env = {
      "DATABASE_URL" => "mysql2://root:secret@127.0.0.1/rails_event_store?pool=5"
    }
    job['test', env, job_name['test', gem_name, 'mysql'], gem_name]
  }]
postgres_compat =
  merge[RDBMS_GEMS, ->(gem_name) {
    env = {
      "DATABASE_URL" => "postgres://postgres:secret@localhost/rails_event_store?pool=5"
    }
    job['test', env, job_name['test', gem_name, 'postgres'], gem_name]
  }]
json_compat =
  merge[DATATYPE_GEMS, ->(gem_name) {
    env = {
      "DATA_TYPE"    => "json",
      "DATABASE_URL" => "postgres://postgres:secret@localhost/rails_event_store?pool=5"
    }
    job['test', env, job_name['test', gem_name, 'data_type_json'], gem_name]
  }]
jsonb_compat =
  merge[DATATYPE_GEMS, ->(gem_name) {
    env = {
      "DATA_TYPE" => "jsonb",
      "DATABASE_URL" => "postgres://postgres:secret@localhost/rails_event_store?pool=5"
    }
    job['test', env, job_name['test', gem_name, 'data_type_jsonb'], gem_name]
  }]

jobs = [
  check_config,
  mutations,
  rubies,
  rails,
  mysql_compat,
  postgres_compat,
  json_compat,
  jsonb_compat
]
workflows =
  [
    Workflow("Check configuration", %w[check_config]),
    Workflow("Current", mutations.keys.zip(rubies.keys.take(GEMS.size)).flat_map { |mutate_name, test_name|
      Requires(mutate_name => test_name)
    }),
    Workflow("Ruby", rubies.keys.drop(GEMS.size)),
    Workflow("Rails", rails.keys),
    Workflow("Database", [mysql_compat, postgres_compat, json_compat, jsonb_compat].flat_map(&:keys)),
  ]

File.open(".circleci/config.yml", "w") do |f|
  f << <<~EOS << YAML.dump(Config(merge[jobs], merge[workflows])).gsub("---", "")
    # This file is generated by .circleci/config.rb, do not edit it manually!
    # Edit .circleci/config.rb and run ruby .circleci/config.rb
  EOS
end
