require 'rails_helper'

RSpec.describe HlsSessionRecord, type: :model do
  describe 'associations' do
    it { should belong_to(:user) }
  end

  describe 'validations' do
    it { should validate_presence_of(:session_id) }
    it { should validate_presence_of(:segment_dir) }
  end

  describe 'uniqueness' do
    it 'enforces unique session_id' do
      user = create(:user)
      create(:hls_session_record, user: user, session_id: 'fixed_session_id_123')
      duplicate = build(:hls_session_record, user: user, session_id: 'fixed_session_id_123')
      expect(duplicate).not_to be_valid
    end
  end
end
