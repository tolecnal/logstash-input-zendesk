# Logstash Zendesk Input Plugin

This input fetches data from Zendesk and generates Logstash events for indexing into Elasticsearch.
It uses the official Zendesk ruby client api (https://github.com/zendesk/zendesk_api_client_rb).  
Currently, the input supports organization, user, ticket, ticket comment and forum object types.  
It assumes that the user specified has the appropriate Zendesk permissions to access the fetched objects.

Just sharing what I have been using and I hope it helps other folks get started.

Disclaimer:  I am not a developer and this is my first Ruby program :)

```
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
#         document_type => "%{type}"
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
```

This is a plugin for [Logstash](https://github.com/elastic/logstash).

It is fully free and fully open source. The license is Apache 2.0, meaning you are pretty much free to use it however you want in whatever way.


