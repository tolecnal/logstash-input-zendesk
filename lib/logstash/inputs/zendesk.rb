# encoding: utf-8
require "logstash/inputs/base"
require "logstash/namespace"
require "logstash/util/socket_peer"
require 'zendesk_api'

# This input will fetch data from Zendesk and generate Logstash events for indexing into Elasticsearch.
# It uses the official Zendesk ruby client api (zendesk_api) and is compatible with Zendesk api v2.  
# Currently, the input supports Zendesk organization, user, ticket, ticket comment and forum objects.  
# It assumes that the user specified has the appropriate Zendesk permissions to access the fetched objects.
#
# Sample configuration:
#
# [source,ruby]
# ----------------------------------
#     input 
#     { 
#       zendesk
#       {
#         domain => "company.zendesk.com"
#         # Specify either user and password or user and api_token for authentication
#         user => "user@company.com"
#         # password => "your_password"
#         api_token => "your_api_token"
#         organizations => true
#         users => true
#         tickets => true
#         tickets_last_updated_n_days_ago => 1
#         comments => false
#         append_comments_to_tickets => false
#		  topics = false
#         sleep_between_runs => 30
#       }
#     }
#
#     output 
#     {
#       elasticsearch
#       {
#         host => "localhost"
#         port => "9200"
#         index => "zendesk"
#         # Referenced in plugin code. Do not change.
#         index_type => "%{type}"
#         # Referenced in plugin code. Do not change.
#         document_id => "%{id}"
#         protocol => "http"
#         manage_template => false
#         # If using shield with authentication (LS 1.5+)
#         user => "shield_user"
#         password => "shield_password"
#       }
#     }
# ----------------------------------

class LogStash::Inputs::Zendesk < LogStash::Inputs::Base
  config_name "zendesk"
  milestone 1

  default :codec, "json"

  # Zendesk domain.  
  #   Example: 
  #     elasticsearch.zendesk.com
  config :domain, :validate => :string, :required => true

  # Zendesk user with admin role.
  #   Requires a Zendesk admin user account.
  config :user, :validate => :string, :required => true

  # Authentication method using user password
  config :password, :validate => :password

  # Authentication method using api token instead of password
  config :api_token, :validate => :password

  # Whether or not to fetch organizations.
  config :organizations, :validate => :boolean, :default => true

  # Whether or not to fetch users.
  config :users, :validate => :boolean, :default => true

  # Whether or not to fetch tickets.
  config :tickets, :validate => :boolean, :default => true
  
  # Whether or not to fetch topics.
  config :topics, :validate => :boolean, :default => true

  # This is the criteria for fetching tickets in the form of last updated N days ago.
  # Updated tickets include new tickets.
  #   Examples:
  #     0.5 = updated in the past 12 hours
  #     1  = updated in the past day
  #     7 = updated in the past week
  #     -1 = get all tickets (when this mode is chosen, the plugin will run only once, not continuously)
  config :tickets_last_updated_n_days_ago, :validate => :number, :default => 1

  # Whether or not to fetch ticket comments (certainly, you can only fetch comments if you are fetching tickets).
  config :comments, :validate => :boolean, :default => false

  # This is added for search use cases.  Enabling this will add comments to each ticket document created.
  # This option requires comments => true.
  config :append_comments_to_tickets, :validate => :boolean, :default => false

  # This is the sleep time (minutes) between plugin runs.  Does not apply when tickets_last_updated_n_days_ago => -1.
  config :sleep_between_runs, :validate => :number, :default => 5

  # Creates a Zendesk client.
  public
  def register
  end # end register

  # Initiate a Zendesk client.
  def zendesk_client
    @logger.info("Creating a Zendesk client", :user => @user, :api_version => "https://#{@domain}/api/v2")
    @zd_client = ZendeskAPI::Client.new do |zconfig|
      zconfig.url = "https://#{@domain}/api/v2" # Use zendesk api v2
      zconfig.username = @user
      if @password.nil? && @api_token.nil?
        @logger.error("Must specify either a password or api_token.", :password => @password, :api_token => @api_token)
      elsif !@password.nil? && @api_token.nil?
        zconfig.password = @password.value
      elsif @password.nil? && !@api_token.nil?
        zconfig.token = @api_token.value
      else @logger.error("Cannot specify both password and api_token input parameters.", :password => @password, :api_token => @api_token)
      end
      zconfig.retry = true # this is a feature of the Zendesk client api, it automatically retries when hitting rate limits
      if @logger.debug?
        zconfig.logger = @logger
      end
    end
    # Zendesk automatically switches to anonymous user login when credentials are invalid.
    # When this happens, no data will be fetched. This is added to prevent further execution due to invalid credentials.
    if @zd_client.current_user.id.nil?
      raise RuntimeError.new("Cannot initialize a valid Zendesk client.  Please check your login credentials.")
    else
      @logger.info("Successfully initialized a Zendesk client", :user => @user)
    end      
  end

  # Get organizations. Organizations will be indexed using "organization" type.
  private
  def get_organizations(output_queue)
    begin
      @logger.info("Processing organizations ...")
      orgs = @zd_client.organizations
      @logger.info("Number of organizations", :count => orgs.count)
      count = 0
      orgs.all do |org|
        count = count + 1
        @logger.info("Organization", :name => org.name, :progress => "#{count}/#{orgs.count}")
        event = LogStash::Event.new()
        org.attributes.each do |k,v|
          event[k] = v
        end # end attrs
        event["type"] = "organization"
        event["id"] = org.id
        decorate(event)
        output_queue << event
        @logger.info("Done processing organization", :name => org.name)
        @org_hash[org.id] = org
      end # end orgs loop 
    rescue => e
      @logger.error(e.message, :method => "get_organizations", :trace => e.backtrace)
      puts e.backtrace
    end
    @logger.info("Done processing organizations.")
  end # end get_organizations

  # Get users.  Users will be indexed using "user" type.  
  private
  def get_users(output_queue)
    begin
      @logger.info("Processing users ...")
      users = @zd_client.users
      @logger.info("Number of users", :count => users.count)
      count = 0
      users.all do |user|
        count = count + 1
        @logger.info("User", :name => user.name, :progress => "#{count}/#{users.count}")
        event = LogStash::Event.new()
        user.attributes.each do |k,v|
          if k == "user_fields"
            v.each do |ik,iv|
              event[ik] = iv
            end
          else
            event[k] = v
          end # end user fields
        end # end attrs
        event["type"] = "user"
        event["id"] = user.id
        # Pull organization name into user object for reporting purposes
        if @organizations && !@org_hash[user.organization_id].nil?
          event["organization_name"] = @org_hash[user.organization_id].name
        end
        decorate(event)
        output_queue << event
        @logger.info("Done processing user", :name => user.name)
        @user_hash[user.id] = user
      end # end user loop 
    rescue => e
      @logger.error(e.message, :method => "get_users", :trace => e.backtrace)
    end
    @logger.info("Done processing users.")
  end # end get_users

  # Get organization id by name
  private
  def get_org_id(org_name)
    org_id = -1
    @org_hash.each do |k, v|
      if v.name == org_name
          org_id = k
          break
      end
    end
    org_id
  end
  
  # Get tickets.  Tickets will be indexed using "ticket" type.
  # This input uses the Zendesk incremental export api (http://developer.zendesk.com/documentation/rest_api/ticket_export.html) 
  # to retrieve tickets due to Zendesk ticket archiving policies 
  # (https://support.zendesk.com/entries/28452998-Ticket-Archiving) - so that 
  # tickets closed > 120 days ago can be fetched.
  private
  def get_tickets(output_queue, last_updated_n_days, get_comments)
    # Pull in ticket field names because Zendesk incremental export api 
    # returns fields names in the format `field_<field_id>`. 
    begin
      @ticketfields = Hash.new
      ticket_fields = @zd_client.ticket_fields
      ticket_fields.each do |tf|
        @ticketfields["field_#{tf.id}"] = tf.title.downcase.gsub(' ', '_')
      end
      @logger.info("Processing tickets ...")
      next_page = true
      if last_updated_n_days != -1
        start_time = Time.now.to_i - (86400 * last_updated_n_days)
      else
        start_time = 0
      end
      tickets = ZendeskAPI::Ticket.incremental_export(@zd_client, start_time)
      next_page_from_each = ""
      next_page_from_next = ""    
      count = 0
      while next_page && tickets.count > 0
        @logger.info("Next page from Zendesk api", :next_page_url => tickets.instance_variable_get("@next_page"))
        @logger.info("Number of tickets returned from current incremental export page request", :count => tickets.count)
        tickets.each do |ticket|
          next_page_from_each = tickets.instance_variable_get("@next_page")
          if ticket.status == 'Deleted'
            # Do nothing, previously deleted tickets will show up in incremental export, but does not make sense to fetch
            @logger.info("Skipping previously deleted ticket", :ticket_id => ticket.id)
          else
            count = count + 1
            @logger.info("Ticket", :id => ticket.id, :progress => "#{count}/#{tickets.count}")
            process_ticket(output_queue,ticket,get_comments)
            @logger.info("Done processing ticket", :id => ticket.id)
          end #end Deleted status check
        end # end ticket loop
        tickets.next
        next_page_from_next = tickets.instance_variable_get("@next_page")
        # Zendesk api creates a next page attribute in its incremental export response including a generated
        # start_time for the "next page" request.  Occasionally, it generates 
        # the next page request with the same start_time as the originating request.
        # When this happens, it will keep requesting the same page over and over again.  Added a check to workaround this
        # behavior.
        if next_page_from_next == next_page_from_each
          next_page = false
        end
        count = 0
      end # end while
    # Zendesk api generates the start_time for the next page request.
    # If it ends up generating a start time that is within 5 minutes from now, it will return the following message
    # instead of a regular json response:
    # "Too recent start_time. Use a start_time older than 5 minutes". 
    # This is added to ignore the message and treat it as benign.
    rescue => e
      if e.message.index 'Too recent start_time'
      # Do nothing for "Too recent start_time. Use a start_time older than 5 minutes" message returned by Zendesk api
      # This simply means that there are no more pages to fetch
        next_page = false
      else
        @logger.error(e.message, :method => "get_tickets", :trace => e.backtrace)
      end
    end
    @logger.info("Done processing tickets.")
  end # end get_tickets

  # Index each ticket fetched back.  Process comments if get_comments => true.
  private
  def process_ticket(output_queue, ticket, get_comments)
    begin
      event = LogStash::Event.new()
      ticket.attributes.each do |k,v|
        # Zendesk incremental export api returns unfriendly field names for ticket fields (eg. field_<num>).
        # This performs conversion back to the right types based on Zendesk field naming conventions
        # and pulls in actual field names from ticket fields.  And also performs other type conversions.
        if k == "full_resolution_time_in_minutes"
          full_resolution = ""
          full_resolution_time = v.to_i
          if ((full_resolution_time >=1) && (full_resolution_time <= 1440))
            full_resolution="0 - 1 days"
          elsif ((full_resolution_time > 1440) && (full_resolution_time <= 10080))
            full_resolution="1 - 7 days"
          elsif ((full_resolution_time > 10080) && (full_resolution_time <= 20160))
            full_resolution="7 - 14 days"
          elsif (full_resolution_time > 20160)
            full_resolution="> 14 days"
          else full_resolution = "Not Applicable" 
          end
          event["full_resolution_time_range"] = full_resolution
          event["full_resolution_time_in_minutes"] = full_resolution_time
        elsif k == "first_reply_time_in_minutes"
          first_reply = ""
          first_reply_time = v.to_i
          if ((first_reply_time >=1) && (first_reply_time <= 60))
            first_reply="0 - 1 hours"
          elsif ((first_reply_time > 60) && (first_reply_time <= 480))
            first_reply="1 - 8 hours"
          elsif ((first_reply_time > 480) && (first_reply_time <= 1440))
            first_reply="8 - 24 hours"
          elsif (first_reply_time > 1440)
            first_reply="> 24 hours"
          else first_reply = "Not Applicable" 
          end
          event["first_reply_time_range"] = first_reply
          event["first_reply_time_in_minutes"] = first_reply_time                  
        elsif k.match(/^field_/) && !@ticketfields[k].nil?
          if @ticketfields[k] == "total_time_spent_(sec)"
            total_time = ""
            total_time_spent_sec = v.to_i
            if ((total_time_spent_sec >=1) && (total_time_spent_sec <= 3600))
              total_time="0 - 1 hours"
            elsif ((total_time_spent_sec > 3600) && (total_time_spent_sec <= 28800))
              total_time="1 - 8 hours"
            elsif ((total_time_spent_sec > 28800) && (total_time_spent_sec <= 86400))
              total_time="8 - 24 hours"
            elsif (total_time_spent_sec > 86400)
              total_time="> 24 hours"
            else total_time = "Not Applicable" 
            end
            event["total_time_spent_range"] = total_time
            event["total_time_spent_(sec)"] = total_time_spent_sec
          else      
            event[@ticketfields[k]] = v
          end
        elsif k.match(/_minutes/) || k.match(/_id/)
          event[k] = v.nil? ? nil : v.to_i
        elsif k.match(/_at$/)
          event[k] = v.nil? ? nil : Time.parse(v).iso8601    
        elsif k == "organization_name"
          # it appears that Zendesk has changed their incremental export API to return organization_id
          # instead of organization_name, but the ruby api has not yet been updated.
          # this is to workaround it
          event["org_id"] = get_org_id(v)
          event["organization_name"] = v
        else
          event[k] = v
        end
      end # end ticket fields
      event["type"] = "ticket"
      event["id"] = ticket.id
      if get_comments
        event["comments"] = get_ticket_comments(output_queue, ticket, @append_comments_to_tickets)
      end
      decorate(event)
      output_queue << event
    rescue => e
      @logger.error(e.message, :method => "process_ticket", :trace => e.backtrace)
    end
  end # end process tickets
  
  # Get ticket comments.  Comments will be indexed using the "comment" type.
  # If append_comments => true, create a single large text field bundling up related comments (sorted descendingly) 
  # and append to parent ticket when indexing tickets.
  # For comments with longitude and latitude values, a geoJSON array named "geocode" is automatically created for Kibana 3's bettermap.
  # Note that this requires your mapping to have geocode field configured to be geo_point data type.
  # Also pull in several ticket, user and organization fields that may be useful for reporting such as author name, etc..
  private
  def get_ticket_comments(output_queue, ticket, append_comments)
    begin
      all_comments = ""
      comment_arr = Array.new
      comments = @zd_client.tickets.find(id: ticket.id).comments
      @logger.info("Processing comments", :ticket_id => ticket.id, :number_of_comments => comments.count())
      count = 0
      comments.all do |comment|
        count = count + 1
        @logger.info("Comment", :id => comment.id, :progress => "#{count}/#{comments.count}")
        if append_comments # append comments as a single large text field to ticket
          @logger.info("Appending comment to ticket", :comment_id => comment.id, :ticket_id => ticket.id)
          tmp_comments = ""
          tmp_comments << "---------------------------------------------------\n"
          tmp_comments << "Public: #{comment.public}\n"
          author_name = @users && !@user_hash[comment.author_id].nil? ? @user_hash[comment.author_id].name : nil
          tmp_comments << "Author: #{author_name}\n"
          tmp_comments << "Created At: #{comment.created_at}\n\n"
          tmp_comments << "#{comment.body}\n"
          comment_arr << "#{tmp_comments}\n"
        end
        event = LogStash::Event.new()
        comment.attributes.each do |k,v|
          event[k] = v
        end # end attrs
        # Construct geoJSON array for Kibana
        if (!comment.metadata.system.longitude.nil?) && (!comment.metadata.system.latitude.nil?)
          geo_json = Array.new
          geo_json[0] = comment.metadata.system.longitude
          geo_json[1] = comment.metadata.system.latitude
          event["geocode"] = geo_json
        end
        # Additional ticket fields
        event["ticket_subject"] = ticket.subject
        event["ticket_id"] = ticket.id
        event["ticket_organization_name"] = ticket.organization_name
        event["ticket_requester"] = ticket.req_name
        event["ticket_assignee"] = ticket.assignee_name
        # Additional org fields
        if (@organizations && !@org_hash[get_org_id(ticket.organization_name)].nil?) 
          event["ticket_org_status"] = @org_hash[get_org_id(ticket.organization_name)].organization_fields.org_status
        end 
        if (@organizations && !@org_hash[get_org_id(ticket.organization_name)].nil?) 
          event["ticket_org_created_at"] = @org_hash[get_org_id(ticket.organization_name)].created_at
        end          
        if ((@organizations && !@org_hash[get_org_id(ticket.organization_name)].nil?) && (@users && !@user_hash[comment.author_id].nil?))
          author_org_id = @user_hash[comment.author_id].organization_id
        if !@org_hash[author_org_id].nil?
            event["author_organization_name"] = @org_hash[author_org_id].name
          end
        end   
        # Additional user fields
        if (@users && !@user_hash[comment.author_id].nil?) 
          event["author_name"] = @user_hash[comment.author_id].name
        end
        event["type"] = "comment"
        event["id"] = comment.id
        decorate(event)
        output_queue << event
        @logger.info("Done processing comment", :id => comment.id)
      end #end comment loop
    rescue => e
        @logger.error(e.message, :method => "get_ticket_comments", :trace => e.backtrace)
    end
    if comment_arr.any?
      comment_arr.reverse.each { |x|
        all_comments << x.to_s
      }
      @logger.info("Done processing comments.")
      all_comments
    end
  end


  # Get topics. Topics will be indexed using "topic" type.
  private
  def get_topics(output_queue)
    begin
      get_forums
      @logger.info("Processing topics ...")
      topics = @zd_client.topics
      @logger.info("Number of topics", :count => topics.count)
      count = 0
      topics.all do |topic|
        count = count + 1
        @logger.info("Topic", :title => topic.title, :progress => "#{count}/#{topics.count}")
        event = LogStash::Event.new()
        topic.attributes.each do |k,v|
          event[k] = v
        end # end attrs
        event["type"] = "topic"
        event["id"] = topic.id
        # topic.forum.name is slow, not using it
        event["forum_name"] = @forum_hash[topic.forum_id]
        event["author_name"] = !@user_hash[topic.submitter_id].nil? ? @user_hash[topic.submitter_id].name : nil
        decorate(event)
        output_queue << event
        @logger.info("Done processing topic", :title => topic.title)
      end # end topics loop 
    rescue => e
      @logger.error(e.message, :method => "get_topics", :trace => e.backtrace)
      puts e.backtrace
    end
    @logger.info("Done processing topics.")
  end # end get_topics
  
  # Get forums. 
  private
  def get_forums
    begin
      @logger.info("Processing forums ...")
      forums = @zd_client.forums
      @logger.info("Number of forums", :count => forums.count)
      count = 0
      forums.all do |forum|
        count = count + 1
        @logger.info("Forum", :name => forum.name, :progress => "#{count}/#{forums.count}")
        @forum_hash[forum.id] = forum.name
        @logger.info("Done processing forum", :name => forum.name)
      end # end forums loop 
    rescue => e
      @logger.error(e.message, :method => "get_forums", :trace => e.backtrace)
      puts e.backtrace
    end
    @logger.info("Done processing forums.")
  end # end get_forums  


  # Run Zendesk input continuously at specified sleep intervals.  If tickets_last_updated_n_days_ago => -1,
  # run only once to perform a full fetch of all tickets from Zendesk.
  public
  def run(output_queue)
    loop do
      start = Time.now
      @logger.info("Starting Zendesk input run.", :start_time => start)
      puts "Starting Zendesk input run: " + start.to_s
      @org_hash = Hash.new
      @user_hash = Hash.new   
      @forum_hash = Hash.new
      zendesk_client
      @organizations ? get_organizations(output_queue) : nil
      @users ? get_users(output_queue) : nil
      @tickets ? get_tickets(output_queue, @tickets_last_updated_n_days_ago, @comments) : nil
      @topics ? get_topics(output_queue) : nil
      @logger.info("Completed in (minutes).", :duration => ((Time.now - start)/60).round(2))
      puts "Completed in: " + (((Time.now - start)/60).round(2)).to_s
      @org_hash = nil
      @user_hash = nil
      @forum_hash = nil
      @zd_client = nil      
      if @tickets_last_updated_n_days_ago == -1
        break
      end
      @logger.info("Sleeping before next run ...", :minutes => @sleep_between_runs)
      sleep(@sleep_between_runs * 60)
    end # end loop
    rescue LogStash::ShutdownSignal
  end # def run
end # class LogStash::Inputs::Zendesk

