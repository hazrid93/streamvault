# frozen_string_literal: true

# GET /transcode/keyframe?url=...&t=... — the video keyframe at or before t.
# The player starts copy-mode streams there so seeks and resumes can copy the
# video instead of re-encoding it from an exact, non-keyframe timestamp.
class TranscodeKeyframeController < ApplicationController
  include StreamUrlValidation

  before_action :authenticate_user!

  def show
    input_url = params[:url].to_s
    unless valid_stream_url?(input_url) && verify_stream_url!
      render json: { seconds: nil }, status: :bad_request
      return
    end

    seconds = TranscodeService.keyframe_at_or_before(
      input_url,
      seconds: params[:t],
      headers: stream_upstream_headers(input_url, current_user)
    )
    render json: { seconds: seconds }
  end
end
