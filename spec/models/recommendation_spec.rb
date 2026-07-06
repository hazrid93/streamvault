require 'rails_helper'

RSpec.describe Recommendation, type: :model do
  describe 'validations' do
    it { should validate_presence_of(:tmdb_id) }
    it { should validate_presence_of(:imdb_id) }
  end

  describe 'associations' do
    it { should belong_to(:user) }
  end

  describe '.ordered' do
    it 'returns recommendations ordered by position' do
      user = create(:user)
      third = create(:recommendation, user: user, position: 3)
      first = create(:recommendation, user: user, position: 1)
      second = create(:recommendation, user: user, position: 2)

      expect(user.recommendations.ordered.to_a).to eq([ first, second, third ])
    end
  end

  describe '.replace_recommendations' do
    let(:user) { create(:user) }

    it 'replaces all recommendations in a single transaction' do
      create(:recommendation, user: user, tmdb_id: 999, position: 0)
      items = [
        { tmdb_id: 1, imdb_id: 'tt0000001', title: 'A', poster_url: nil, type: 'movie', year: '2020' },
        { tmdb_id: 2, imdb_id: 'tt0000002', title: 'B', poster_url: nil, type: 'movie', year: '2021' }
      ]

      expect {
        described_class.replace_recommendations(user, items)
      }.to change { user.recommendations.count }.from(1).to(2)

      positions = user.recommendations.ordered.pluck(:position)
      expect(positions).to eq([ 0, 1 ])
    end

    it 'dedupes by tmdb_id to avoid RecordNotUnique on the unique index' do
      items = [
        { tmdb_id: 1, imdb_id: 'tt0000001', title: 'A', poster_url: nil, type: 'movie', year: '2020' },
        { tmdb_id: 1, imdb_id: 'tt0000001', title: 'A dup', poster_url: nil, type: 'movie', year: '2020' }
      ]

      expect {
        described_class.replace_recommendations(user, items)
      }.to change { user.recommendations.count }.by(1)

      expect(user.recommendations.first.title).to eq('A')
    end

    it 'leaves the user with zero recommendations when items is empty' do
      create(:recommendation, user: user)
      described_class.replace_recommendations(user, [])
      expect(user.recommendations.count).to eq(0)
    end

    it 'handles duplicate tmdb_ids in items without raising RecordNotUnique' do
      create(:recommendation, user: user, tmdb_id: 100, position: 0)
      items = [
        { tmdb_id: 1, imdb_id: 'tt0000001', title: 'A', poster_url: nil, type: 'movie', year: '2020' },
        { tmdb_id: 1, imdb_id: 'tt0000001', title: 'A dup', poster_url: nil, type: 'movie', year: '2020' },
        { tmdb_id: 2, imdb_id: 'tt0000002', title: 'B', poster_url: nil, type: 'movie', year: '2021' }
      ]

      expect {
        described_class.replace_recommendations(user, items)
      }.not_to raise_error

      # The duplicate should be deduped, leaving 2 recommendations
      expect(user.recommendations.count).to eq(2)
      expect(user.recommendations.ordered.pluck(:tmdb_id)).to eq([ 1, 2 ])
    end
  end
end
