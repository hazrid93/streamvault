# Be sure to restart your server when you modify this file.

# Define an application-wide content security policy.
# See the Securing Rails Applications Guide for more information:
# https://guides.rubyonrails.org/security.html#content-security-policy-header

Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.font_src    :self, :https, :data
    # Posters (cinemeta/image.tmdb.org), the unauthenticated background
    # (images.unsplash.com), and data: URIs for icons.
    policy.img_src     :self, :https, :data
    policy.object_src  :none
    # importmap-rails emits an inline <script type="module">import "application"</script>
    # bootstrap and an inline importmap JSON — both carry the per-request
    # nonce (see content_security_policy_nonce_generator below).  Stimulus
    # controllers themselves load from :self via the importmap.
    policy.script_src  :self
    # Tailwind + per-element inline style="" attributes require
    # unsafe-inline for styles until the inline styles are extracted.
    policy.style_src   :self, :unsafe_inline
    # XHR/fetch only ever targets the same origin (transcode, HLS,
    # progress, tracks, subtitles).  No third-party API calls from JS.
    policy.connect_src :self
    # <video> uses blob: URLs (MediaSource) and the HLS playlist path.
    policy.media_src   :self, "blob:"
    # Specify URI for violation reports
    # policy.report_uri "/csp-violation-report-endpoint"
  end

  # Generate a per-request nonce so importmap-rails' inline
  # <script type="importmap"> and <script type="module"> bootstrap
  # are permitted under a strict script-src.  Using SecureRandom
  # instead of request.session.id because the session is lazily
  # loaded — session.id is nil on GET requests that never write to
  # the session (e.g. the sign-in page), producing an empty nonce
  # that the browser ignores.  With no nonce in the CSP header and
  # no nonce attribute on the inline script tags, script-src 'self'
  # blocks the importmap bootstrap entirely, breaking every Stimulus
  # controller (video player, episode picker, toggles, etc.) — which
  # is why progress saves silently stopped and Continue Watching
  # emptied after the CSP was enabled.
  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base58(32) }
  config.content_security_policy_nonce_directives = %w[script-src style-src]

  # Automatically add `nonce` to `javascript_tag`, `javascript_include_tag`,
  # and `stylesheet_link_tag` if the corresponding directives are specified
  # in `content_security_policy_nonce_directives`.
  config.content_security_policy_nonce_auto = true

  # Report violations without enforcing the policy.
  # config.content_security_policy_report_only = true
end
