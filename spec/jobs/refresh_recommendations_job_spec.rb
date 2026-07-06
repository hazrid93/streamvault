require 'rails_helper'

RSpec.describe RefreshRecommendationsJob, type: :job do
  let(:user) { create(:user) }

  around do |ex|
    old_token = ENV["TMDB_READ_ACCESS_TOKEN"]
    ex.run
  ensure
    ENV["TMDB_READ_ACCESS_TOKEN"] = old_token
  end

  describe '#perform' do
    it 'does nothing when the user does not exist' do
      ENV["TMDB_READ_ACCESS_TOKEN"] = "test_token"
      expect(RecommendationService).not_to receive(:recommendations)
      described_class.perform_now(999_999)
    end

    it 'does nothing when TMDB_READ_ACCESS_TOKEN is blank' do
      ENV["TMDB_READ_ACCESS_TOKEN"] = nil
      expect(RecommendationService).not_to receive(:recommendations)
      described_class.perform_now(user.id)
    end

    it 'replaces recommendations when TMDB succeeds' do
      ENV["TMDB_READ_ACCESS_TOKEN"] = "test_token"
      items = [
        { tmdb_id: 1, imdb_id: 'tt0000001', title: 'A', poster_url: nil, type: 'movie', year: '2020' }
      ]
      result = ServiceResult.success(items)
      allow(RecommendationService).to receive(:recommendations).with(user).and_return(result)
      allow(Recommendation).to receive(:replace_recommendations)

      described_class.perform_now(user.id)

      expect(Recommendation).to have_received(:replace_recommendations).with(user, items)
    end

    it 'uses an empty array when RecommendationService fails' do
      ENV["TMDB_READ_ACCESS_TOKEN"] = "test_token"
      allow(RecommendationService).to receive(:recommendations).with(user)
        .and_return(ServiceResult.failure('TMDB down'))
      allow(Recommendation).to receive(:replace_recommendations)

      described_class.perform_now(user.id)

      expect(Recommendation).to have_received(:replace_recommendations).with(user, [])
    end

    it 'swallows unexpected errors (does not raise)' do
      ENV["TMDB_READ_ACCESS_TOKEN"] = "test_token"
      allow(RecommendationService).to receive(:recommendations).and_raise(StandardError, 'boom')

      expect { described_class.perform_now(user.id) }.not_to raise_error
    end
  end

  describe '.enqueue_debounced' do
    it 'enqueues a job when no lock is held' do
      allow(Rails.cache).to receive(:write)
        .with(anything, true, hash_including(unless_exist: true))
        .and_return(true)

      expect {
        described_class.enqueue_debounced(user.id)
      }.to have_enqueued_job(described_class).with(user.id)
    end

    it 'does not enqueue a duplicate when the lock is already held' do
      allow(Rails.cache).to receive(:write)
        .with(anything, true, hash_including(unless_exist: true))
        .and_return(false)

      expect {
        described_class.enqueue_debounced(user.id)
      }.not_to have_enqueued_job(described_class)
    end
  end
end
