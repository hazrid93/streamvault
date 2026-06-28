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
    # No inline <script> tags are used — importmap + Stimulus modules
    # all load from :self.  Keep script-src strict so any future XSS
    # cannot execute inline code or load scripts from other hosts.
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

  # Generate session nonces for permitted importmap, inline scripts, and inline styles.
  # config.content_security_policy_nonce_generator = ->(request) { request.session.id.to_s }
  # config.content_security_policy_nonce_directives = %w[script-src style-src]

  # Automatically add `nonce` to `javascript_tag`, `javascript_include_tag`, and `stylesheet_link_tag`
  # if the corresponding directives are specified in `content_security_policy_nonce_directives`.
  # config.content_security_policy_nonce_auto = true

  # Report violations without enforcing the policy.
  # config.content_security_policy_report_only = true
end
