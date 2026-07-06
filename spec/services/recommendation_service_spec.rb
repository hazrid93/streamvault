require 'rails_helper'

RSpec.describe RecommendationService, type: :service do
  let(:user) { create(:user) }

  around do |ex|
    old_token = ENV["TMDB_READ_ACCESS_TOKEN"]
    ex.run
  ensure
    ENV["TMDB_READ_ACCESS_TOKEN"] = old_token
  end

  describe '.recommendations' do
    it 'returns an empty array when TMDB_READ_ACCESS_TOKEN is blank' do
      ENV["TMDB_READ_ACCESS_TOKEN"] = nil
      result = described_class.recommendations(user)
      expect(result).to be_success
      expect(result.data).to eq([])
    end

    it 'returns an empty array when the user has no watch history' do
      ENV["TMDB_READ_ACCESS_TOKEN"] = "test_token"
      result = described_class.recommendations(user)
      expect(result).to be_success
      expect(result.data).to eq([])
    end

    it 'excludes content already in the user library' do
      ENV["TMDB_READ_ACCESS_TOKEN"] = "test_token"
      create(:watch_history_entry, user: user, imdb_id: 'tt1375666', show_imdb_id: nil)
      create(:library_entry, user: user, imdb_id: 'tt0468569')

      # Stub TMDB to recommend a movie already in the library
      allow_any_instance_of(TmdbService).to receive(:recommendations_for_imdb_id)
        .with('tt1375666')
        .and_return(ServiceResult.success([
          { tmdb_id: 497, imdb_id: 'tt0468569', title: 'In Library', poster_url: nil, type: 'movie', year: '2008' },
          { tmdb_id: 100, imdb_id: 'tt0000123', title: 'New Rec', poster_url: nil, type: 'movie', year: '2020' }
        ]))

      result = described_class.recommendations(user)
      imdb_ids = result.data.map { |r| r[:imdb_id] }
      expect(imdb_ids).to include('tt0000123')
      expect(imdb_ids).not_to include('tt0468569')
    end

    it 'swallows unexpected errors and returns an empty array' do
      ENV["TMDB_READ_ACCESS_TOKEN"] = "test_token"
      create(:watch_history_entry, user: user, imdb_id: 'tt1375666', show_imdb_id: nil)
      allow_any_instance_of(TmdbService).to receive(:recommendations_for_imdb_id)
        .and_raise(StandardError, 'boom')

      result = described_class.recommendations(user)
      expect(result).to be_success
      expect(result.data).to eq([])
    end
  end
end
