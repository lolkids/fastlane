require "fastlane_core"
require "pilot/tester_util"
require 'terminal-table'

module Pilot
  class TesterManager < Manager
    def add_tester(options)
      start(options)

      app = find_app(app_filter: config[:apple_id] || config[:app_identifier])
      UI.user_error!("You must provide either a Apple ID for the app (with the `:apple_id` option) or app identifier (with the `:app_identifier` option)") unless app

      tester = find_or_create_tester(email: config[:email], first_name: config[:first_name], last_name: config[:last_name])

      begin
        groups = Spaceship::TestFlight::Group.add_tester_to_groups!(tester: tester, app: app, groups: config[:groups])
        if tester.kind_of?(Spaceship::Tunes::Tester::Internal)
          UI.success("Successfully added tester to app #{app.name}")
        else
          group_names = groups.map(&:name).join(", ")
          UI.success("Successfully added tester to app #{app.name} in group(s) #{group_names}")
        end
      rescue => ex
        UI.error("Could not add #{tester.email} to app: #{app.name}")
        raise ex
      end
    end

    def find_tester(options)
      start(options)

      tester = Spaceship::Tunes::Tester::Internal.find(config[:email])
      tester ||= Spaceship::Tunes::Tester::External.find(config[:email])

      UI.user_error!("Tester #{config[:email]} not found") unless tester

      describe_tester(tester)
      return tester
    end

    def remove_tester(options)
      start(options)

      tester = Spaceship::Tunes::Tester::External.find(config[:email])
      tester ||= Spaceship::Tunes::Tester::Internal.find(config[:email])
      UI.user_error!("Tester not found: #{config[:email]}") if tester.nil?

      app = find_app(app_filter: config[:apple_id] || config[:app_identifier])
      unless app
        tester.delete!
        UI.success("Successfully removed tester #{tester.email}")
      end

      begin
        # If no groups are passed to options, remove the tester from the app-level,
        # otherwise remove the tester from the groups specified.
        if config[:groups].nil? && tester.kind_of?(Spaceship::Tunes::Tester::External)
          test_flight_tester = Spaceship::TestFlight::Tester.find(app_id: app.apple_id, email: tester.email)
          test_flight_tester.remove_from_app!(app_id: app.apple_id)
          UI.success("Successfully removed tester, #{test_flight_tester.email}, from app: #{app.name}")
        else
          groups = Spaceship::TestFlight::Group.remove_tester_from_groups!(tester: tester, app: app, groups: config[:groups])
          group_names = groups.map(&:name).join(", ")
          UI.success("Successfully removed tester #{tester.email} from app #{app.name} in group(s) #{group_names}")
        end
      rescue => ex
        UI.error("Could not remove #{tester.email} from app: #{ex}")
        raise ex
      end
    end

    def list_testers(options)
      start(options)

      app_filter = (config[:apple_id] || config[:app_identifier])
      if app_filter
        list_testers_by_app(app_filter)
      else
        list_testers_global
      end
    end

    private

    def find_app(app_filter: nil)
      if app_filter
        app = Spaceship::Application.find(app_filter)
        UI.user_error!("Could not find an app by #{app_filter}") unless app
        return app
      end
      nil
    end

    def find_or_create_tester(email: nil, first_name: nil, last_name: nil)
      tester = Spaceship::Tunes::Tester::Internal.find(config[:email])
      tester ||= Spaceship::Tunes::Tester::External.find(config[:email])

      if tester
        UI.success("Existing tester #{tester.email}")
      else
        tester = Spaceship::Tunes::Tester::External.create!(email: config[:email],
                                                            first_name: config[:first_name],
                                                            last_name: config[:last_name])
        UI.success("Successfully added tester: #{tester.email} to your account")
      end
      return tester
    rescue => ex
      UI.error("Could not create tester #{config[:email]}")
      raise ex
    end

    def list_testers_by_app(app_filter)
      app = Spaceship::Application.find(app_filter)
      UI.user_error!("Couldn't find app with '#{app_filter}'") unless app

      int_testers = Spaceship::Tunes::Tester::Internal.all_by_app(app.apple_id)
      ext_testers = Spaceship::Tunes::Tester::External.all_by_app(app.apple_id)

      list_by_app(int_testers, "Internal Testers")
      puts ""
      list_by_app(ext_testers, "External Testers")
    end

    def list_testers_global
      begin
        int_testers = Spaceship::Tunes::Tester::Internal.all
        ext_testers = Spaceship::Tunes::Tester::External.all
      rescue Spaceship::Client::InsufficientPermissions
        UI.user_error!("You don't have the permission to list the testers of your whole team. Please provide an app identifier to list all testers of a specific application.")
      end

      list_global(int_testers, "Internal Testers")
      puts ""
      list_global(ext_testers, "External Testers")
    end

    def list_global(all_testers, title)
      headers = ["First", "Last", "Email", "Groups", "Devices", "Latest Version", "Latest Install Date"]
      list(all_testers, title, headers) do |tester|
        [
          tester.first_name,
          tester.last_name,
          tester.email,
          tester.groups_list,
          tester.devices.count,
          tester.full_version,
          tester.pretty_install_date
        ]
      end
    end

    def list_by_app(all_testers, title)
      headers = ["First", "Last", "Email", "Groups"]
      list(all_testers, title, headers) do |tester|
        [
          tester.first_name,
          tester.last_name,
          tester.email,
          tester.groups_list
          # Testers returned by the query made in the context of an app do not contain
          # the devices, version, or install date information
        ]
      end
    end

    # Requires a block that accepts a tester and returns an array of tester column values
    def list(all_testers, title, headings)
      rows = all_testers.map { |tester| yield tester }
      puts Terminal::Table.new(
        title: title.green,
        headings: headings,
        rows: FastlaneCore::PrintTable.transform_output(rows)
      )
    end

    # Print out all the details of a specific tester
    def describe_tester(tester)
      return unless tester

      rows = []

      rows << ["First name", tester.first_name]
      rows << ["Last name", tester.last_name]
      rows << ["Email", tester.email]

      if tester.groups.length > 0
        rows << ["Groups", tester.groups_list]
      end

      if tester.latest_install_date
        rows << ["Latest Version", tester.full_version]
        rows << ["Latest Install Date", tester.pretty_install_date]
      end

      if tester.devices.length == 0
        rows << ["Devices", "No devices"]
      else
        rows << ["#{tester.devices.count} Devices", ""]
        tester.devices.each do |device|
          current = "\u2022 #{device['model']}, iOS #{device['osVersion']}"

          if rows.last[1].length == 0
            rows.last[1] = current
          else
            rows << ["", current]
          end
        end
      end

      puts Terminal::Table.new(
        title: tester.email.green,
        rows: FastlaneCore::PrintTable.transform_output(rows)
      )
    end
  end
end
