require 'rails_helper'

RSpec.describe "Episodes", type: :request do
  let(:user) { create(:user) }

  describe "GET /episodes/:show_imdb_id" do
    context "when not authenticated" do
      it "redirects to login" do
        get episodes_path(show_imdb_id: "tt0903747")
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "returns success" do
        stub_request(:get, "https://v3-cinemeta.strem.io/meta/series/tt0903747.json")
          .to_return(
            status: 200,
            body: { "meta" => { "id" => "tt0903747", "name" => "Breaking Bad", "videos" => [] } }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        get episodes_path(show_imdb_id: "tt0903747")
        expect(response).to have_http_status(:ok)
      end

      it "rejects a malformed show_imdb_id (SEC-09)" do
        get episodes_path(show_imdb_id: "not_an_imdb_id")
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to eq("Invalid content ID.")
      end
    end
  end
end
