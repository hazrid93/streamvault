# frozen_string_literal: true

require "ipaddr"
require "socket"
require "uri"

module StreamUrlValidation
  PRIVATE_STREAM_NETWORKS = %w[
    0.0.0.0/8
    10.0.0.0/8
    100.64.0.0/10
    127.0.0.0/8
    169.254.0.0/16
    172.16.0.0/12
    192.0.0.0/24
    192.0.2.0/24
    192.168.0.0/16
    198.18.0.0/15
    198.51.100.0/24
    203.0.113.0/24
    224.0.0.0/4
    240.0.0.0/4
    ::1/128
    fc00::/7
    fe80::/10
    ff00::/8
  ].map { |range| IPAddr.new(range) }.freeze

  # Hosts the transcode/HLS proxy is allowed to fetch from.  The
  # stream URL is always a RealDebrid direct-download URL (returned by
  # the resolve 302) or a provider resolve URL (torrentio/comet) when
  # probed before resolution — never an arbitrary user-supplied host.
  # Restricting to these prevents an authenticated user from abusing
  # the server as an open bandwidth/CPU proxy to arbitrary public hosts.
  ALLOWED_STREAM_HOSTS = [
    "real-debrid.com",
    /\.real-debrid\.com\z/i
  ].freeze

  # Provider resolve origins (torrentio/comet) are allowlisted
  # dynamically from StreamProvider.resolve_base_urls so a custom
  # TORRENTIO_API_BASE_URL or COMET_URL is honoured.
  def allowed_stream_host?(host)
    normalized = host.to_s.downcase
    return false if normalized.blank?

    return true if ALLOWED_STREAM_HOSTS.any? do |entry|
      entry.is_a?(Regexp) ? normalized.match?(entry) : normalized == entry || normalized.end_with?(".#{entry}")
    end

    StreamProvider.resolve_base_urls.filter_map { |url| URI.parse(url).host }.any? do |allowed|
      normalized == allowed.downcase || normalized.end_with?(".#{allowed.downcase}")
    end
  rescue URI::InvalidURIError
    false
  end

  # Hosts that belong to a user-configured provider (COMET_URL / TORRENTIO_API_BASE_URL).
  # These are explicitly trusted by the operator — they're not subject to DNS-rebinding
  # attacks (addresses are fixed, either a Tailscale IP or a known hostname) and may
  # legitimately resolve to private/CGNAT addresses (e.g. Tailscale 100.x.x.x).
  def provider_host?(host)
    normalized = host.to_s.downcase
    return false if normalized.blank?

    StreamProvider.resolve_base_urls.filter_map { |url| URI.parse(url).host }.any? do |allowed|
      normalized == allowed.downcase || normalized.end_with?(".#{allowed.downcase}")
    end
  rescue URI::InvalidURIError
    false
  end

  # Validate that +value+ is an http(s) URL whose host is either a user-configured
  # provider (comet/torrentio) or resolves to public addresses only.  Provider hosts
  # bypass the DNS-resolution check because they are explicitly configured by the
  # operator (e.g. COMET_URL on a Tailscale IP) — the DNS-rebinding TOCTOU attack
  # does not apply to fixed IPs or user-chosen hostnames.
  def valid_stream_url?(value)
    uri = URI.parse(value.to_s)
    return false unless uri.is_a?(URI::HTTP) && uri.host.present?
    return false unless allowed_stream_host?(uri.host)

    # Provider-hosted URLs (Comet on Tailscale) bypass the public-address check.
    # Only RealDebrid CDN URLs need DNS resolution to verify they're not private.
    if provider_host?(uri.host)
      @_validated_stream_url = value.to_s
      @_validated_stream_addresses = nil
      return true
    end

    addresses = resolve_public_addresses(uri.host)
    return false if addresses.empty?

    @_validated_stream_url = value.to_s
    @_validated_stream_addresses = addresses
    true
  rescue URI::InvalidURIError
    false
  end

  # Re-resolve the host of the most recently validated URL and confirm
  # every resolved address is still public.  Guards against DNS
  # rebinding: an attacker returns a public IP during #valid_stream_url?
  # and a private IP (e.g. 169.254.169.254) by the time ffmpeg connects.
  # CDN hosts legitimately rotate their address sets, so we check that
  # no current address is private rather than requiring set equality.
  # Call this immediately before spawning the transcode subprocess.
  # Provider-configured hosts bypass this check (user-chosen, not attacker-controlled).
  def verify_stream_url!
    return false unless @_validated_stream_url

    uri = URI.parse(@_validated_stream_url)
    # Provider hosts bypass re-resolution — they're user-configured fixed
    # addresses that can't be DNS-rebinding attacked.
    return true if provider_host?(uri.host)

    current = resolve_public_addresses(uri.host)
    !current.empty?
  rescue URI::InvalidURIError
    false
  end

  # Resolve +host+ and return only the public, non-loopback addresses.
  # Returns an empty array if the host is "localhost", resolves to any
  # private network, or cannot be resolved at all (fail closed).
  def resolve_public_addresses(host)
    normalized_host = host.to_s.downcase
    return [] if normalized_host == "localhost" || normalized_host.end_with?(".localhost")

    addresses = Addrinfo.getaddrinfo(normalized_host, nil, :UNSPEC, :STREAM).map(&:ip_address).uniq
    return [] if addresses.empty?
    return [] if addresses.any? { |address| private_stream_address?(address) }

    addresses
  rescue SocketError
    []
  end

  def private_stream_address?(address)
    ip = IPAddr.new(address)
    PRIVATE_STREAM_NETWORKS.any? { |network| network.include?(ip) }
  rescue IPAddr::InvalidAddressError
    true
  end
end
