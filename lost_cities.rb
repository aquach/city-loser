require 'sinatra/async'
require 'eventmachine'

EM.next_tick do
  EM.add_periodic_timer(1) do
    puts 'tick'
  end
end

class LostCitiesServer < Sinatra::Base
  register Sinatra::Async

  # The root path will serve as a kind of "ping" for our clients.
  # We'll respond to everything with JSON.
  aget '/' do
    response.headers['Content-Type'] = 'application/json'
    body '{"ack": "huzzah!"}'
  end

  aget '/long_poll' do
    waiter = lambda do
      sleep(10)
      return 'thoughts'
    end

    callback = lambda do |output|
      body output
    end

    EM.defer(waiter, callback)
  end

  apost '/' do
    response.headers['Content-Type'] = 'application/json'

    # Find the user. This is left as an exercise for you.
    user = AppPoller.get_user(params[:session_id])
    unless user
      body '{"errors": ["Invalid user!"]}'
      halt 400
    end

    # Find/parse the last post ids.
    # This is a hash like {1 => 56, 2 => 77} where 1 and 2 are Wall id's,
    # and 56 and 77 are the latest message id's this user has for those
    # walls.
    # user.resolve_last_post_ids is for security, stripping out any 
    # walls the user isn't supposed to have access to. Another exercise for you.
    last_post_id = user.resolve_last_post_ids(params[:last_post_id])
    unless last_post_id.any?
      body '{"errors": ["Invalid parameters!"]}'
      halt 400
    end

    # This is the job that will keep checking for new messages for this
    # user's walls
    pollster = proc do
      AppPoller.add_client user
      time, new_posts = 0, false

      # After a minute, most browsers or proxies will have severed the connection,
      # and we don't want this job running forever.
      until time > 60
        # This just compares the user's latest post_id's to the global hash, so it's very cheap.
        new_posts = AppPoller.posts_since?(last_post_id)
        break if new_posts
        sleep 0.5
        time += 0.5
      end

      # If there were new posts, grab them from the database
      new_posts ? AppPoller.posts_since(last_post_id) : []
    end

    # This job takes the new posts (if any), converts them to JSON,
    # and sends the response.
    callback = proc do |new_posts|
      AppPoller.drop_client user
      walls = {:walls => {}}
      new_posts.each do |p|
        walls[:walls][p.wall_id] ||= {:posts => []}
        walls[:walls][p.wall_id][:posts] << p.to_hash
      end
      body walls.to_json
    end

    # Begin asynchronous work
    EM.defer(pollster, callback)
  end
end
