web: bundle exec puma -t 5:5 -p 5000 -e production
worker: bundle exec rake solid_queue:start
release: bundle exec rails db:migrate
