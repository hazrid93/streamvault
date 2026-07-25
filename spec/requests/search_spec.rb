# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Legacy search", type: :request do
  let(:user) { create(:user) }

  it "requires authentication" do
    get search_index_path(q: "Inception")

    expect(response).to redirect_to(new_user_session_path)
  end

  it "preserves old bookmarks by redirecting their query to discovery" do
    sign_in user

    get search_index_path(q: "Inception", page: 2, per_page: 50)

    expect(response).to redirect_to(browse_path(q: "Inception", page: "2", per_page: "50"))
  end
end