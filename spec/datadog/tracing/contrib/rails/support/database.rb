# load the right adapter according to installed gem
module Datadog
  module Tracing
    module Contrib
      module Rails
        module Test
          module Database
            module_function

            # Returns the value to be passed to the environment variable `DATABASE_URL`
            def load_adapter!
              [
                'pg',
                'mysql2',
                'activerecord-jdbcpostgresql-adapter',
                'activerecord-jdbcmysql-adapter',
                'activerecord-trilogy-adapter', # Must come before `trilogy`, as the adapter takes precedence when available
                'trilogy', # Uses the built-in adapter, since Rails 7.1
              ].each do |adapter|
                begin
                  require adapter

                  if adapter == 'pg' || adapter.include?('postgres')
                    connector = postgres_url
                  elsif adapter.include?('mysql')
                    connector = mysql_url
                  elsif adapter.include?('trilogy')
                    connector = mysql_url('trilogy')
                  else
                    raise "Unknown adapter to create DATABASE_URL from: #{adapter}. Please add a URL generator for it."
                  end
                rescue LoadError
                  puts "#{adapter} gem not found, trying another connector"
                else
                  return connector
                end
              end

              raise 'No database adapter found!'
            end

            def postgres_url
              hash = postgres_hash
              "postgres://#{hash[:username]}:#{hash[:password]}@#{hash[:host]}:#{hash[:port]}/#{hash[:database]}"
            end

            def postgres_hash
              {
                database: ENV.fetch('TEST_POSTGRES_DB', 'postgres'),
                host: ENV.fetch('TEST_POSTGRES_HOST', '127.0.0.1'),
                password: ENV.fetch('TEST_POSTGRES_PASSWORD', 'postgres'),
                port: ENV.fetch('TEST_POSTGRES_PORT', 5432),
                username: ENV.fetch('TEST_POSTGRES_USER', 'postgres')
              }
            end

            def mysql_url(protocol = 'mysql2')
              hash = mysql_hash
              "#{protocol}://root:#{hash[:password]}@#{hash[:host]}:#{hash[:port]}/#{hash[:database]}"
            end

            def mysql_hash
              {
                database: ENV.fetch('TEST_MYSQL_DB', 'mysql'),
                host: ENV.fetch('TEST_MYSQL_HOST', '127.0.0.1'),
                password: ENV.fetch('TEST_MYSQL_ROOT_PASSWORD', 'root'),
                port: ENV.fetch('TEST_MYSQL_PORT', '3306')
              }
            end
          end
        end
      end
    end
  end
end
