# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Discovery", type: :request do
  let(:user) { create(:user) }

  describe "GET /browse" do
    it "requires authentication" do
      get browse_path

      expect(response).to redirect_to(new_user_session_path)
    end

    context "when authenticated" do
      before { sign_in user }

      it "combines title search with catalog discovery" do
        stub_cinemeta_search(
          movies: [{ "id" => "tt1375666", "name" => "Inception", "releaseInfo" => "2010" }],
          series: [{ "id" => "tt0903747", "name" => "Breaking Bad", "releaseInfo" => "2008-2013" }]
        )

        get browse_path(q: "dreams", type: "all")

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Discover", "Inception", "Breaking Bad")
        expect(response.body).to include("2</span> matches")
      end

      it "filters search results by content type" do
        stub_cinemeta_search(
          movies: [{ "id" => "tt1375666", "name" => "Inception", "releaseInfo" => "2010" }],
          series: [{ "id" => "tt0903747", "name" => "Breaking Bad", "releaseInfo" => "2008-2013" }]
        )

        get browse_path(q: "drama", type: "show")

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Breaking Bad")
        expect(response.body).not_to include("Inception")
      end

      it "paginates title-search results" do
        movies = 50.times.map do |index|
          { "id" => "tt#{index.to_s.rjust(7, '0')}", "name" => "Movie #{index}", "releaseInfo" => "2020" }
        end
        stub_cinemeta_search(movies: movies, series: [])

        get browse_path(q: "movie", type: "all", page: 2)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Showing 26–50 of 50 results")
      end

      it "escapes external API titles" do
        stub_cinemeta_search(
          movies: [{ "id" => "tt0000001", "name" => "<script>alert(1)</script>", "releaseInfo" => "2020" }],
          series: []
        )

        get browse_path(q: "test", type: "all")

        expect(response.body).to include("&lt;script&gt;")
        expect(response.body).not_to include("<script>alert(1)</script>")
      end
    end
  end

  def stub_cinemeta_search(movies:, series:)
    stub_request(:get, %r{v3-cinemeta\.strem\.io/catalog/movie/top/search=.*\.json})
      .to_return(status: 200, body: { "metas" => movies }.to_json, headers: { "Content-Type" => "application/json" })
    stub_request(:get, %r{v3-cinemeta\.strem\.io/catalog/series/top/search=.*\.json})
      .to_return(status: 200, body: { "metas" => series }.to_json, headers: { "Content-Type" => "application/json" })
  end
end