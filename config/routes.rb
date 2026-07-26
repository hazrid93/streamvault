Rails.application.routes.draw do
  devise_for :users, skip: :all

  devise_scope :user do
    get "pin", to: "pin_access#new", as: :new_user_session
    post "pin", to: "pin_access#create", as: :user_session
    delete "pin", to: "pin_access#destroy", as: :destroy_user_session
  end

  # Root
  root "home#index"

  # Search
  resources :search, only: [ :index ]

  # Browse by category / genre / sort
  get "browse", to: "browse#index", as: :browse

  # Person filmography (cast click-through)
  get "person", to: "person#index", as: :person

  # Content detail
  get "content/:type/:imdb_id", to: "content#show", as: :content
  get "content/:type/:imdb_id/status", to: "content#status", as: :content_status
  get "content/:type/:imdb_id/episode_streams", to: "content#episode_streams", as: :episode_streams
  get "content/:type/:imdb_id/stream_results/:provider", to: "content#stream_results", as: :content_stream_results
  get "content/:type/:imdb_id/similar_results", to: "content#similar_results", as: :content_similar_results

  # Library
  resources :library, only: [ :index, :create, :update, :destroy ]

  # Wishlist
  resources :wishlist, only: [ :index, :create, :destroy ] do
    member do
      post :move_to_library
    end
  end

  # Watch History
  resources :watch_history, only: [ :index, :destroy ] do
    collection do
      delete :clear_all
    end
  end

  # Episodes
  get "episodes/:show_imdb_id", to: "episodes#index", as: :episodes

  # Streaming
  resources :streaming, only: [ :create, :show ] do
    collection do
      get :resume
      post :stall_telemetry
    end
    member do
      patch :progress
    end
  end

  # FFmpeg transcode proxy (MKV → fMP4 with AAC audio)
  get "transcode/duration", to: "transcode_duration#show", as: :transcode_duration
  get "transcode/tracks", to: "transcode_tracks#show", as: :transcode_tracks
  get "transcode/subtitles", to: "transcode_subtitles#show", as: :transcode_subtitles
  get "transcode/thumbnail", to: "transcode_thumbnail#show", as: :transcode_thumbnail
  get "transcode", to: "transcode#stream", as: :transcode_stream

  # HLS streaming (iOS fallback — iPhone Safari lacks MSE support)
  post "hls/start", to: "hls#start", as: :hls_start
  get "hls/:id/playlist.m3u8", to: "hls#playlist", as: :hls_playlist
  get "hls/:id/:segment", to: "hls#segment", as: :hls_segment, constraints: { segment: /\d+\.ts/ }
  post "hls/:id/stop", to: "hls#stop", as: :hls_stop

  # Settings
  get "settings", to: "settings#show", as: :settings
  patch "settings", to: "settings#update"
  patch "settings/pin", to: "settings#update_pin", as: :settings_pin
  delete "settings/local_torrents", to: "settings#clear_local_torrents", as: :settings_local_torrents
  get "cache_status", to: "cache_status#show", as: :cache_status

  # Direct stream proxy (bypass ffmpeg for browser-compatible content)
  get "direct_stream", to: "direct_stream#show", as: :direct_stream
  get "local_torrent/status", to: "local_torrent_status#show", as: :local_torrent_status
  post "local_torrent/stop", to: "local_torrent_status#stop", as: :stop_local_torrent
  resources :cast_sessions, only: %i[create destroy]

  # Health check
  get "up" => "rails/health#show", as: :rails_health_check
end
