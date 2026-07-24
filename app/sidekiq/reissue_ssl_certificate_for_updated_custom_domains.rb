# frozen_string_literal: true

class ReissueSslCertificateForUpdatedCustomDomains
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :low

  def perform
    CustomDomain.alive.where.not(ssl_certificate_issued_at: nil).find_each do |custom_domain|
      # Legacy records can carry domains that fail current validations (e.g.
      # empty labels like "example..com"). reset_ssl_certificate_issued_at!
      # runs save!, which would raise RecordInvalid for them and — with
      # retry: 0 — abort the whole sweep, leaving every domain after them
      # unrenewed. Skip them; they can't get a certificate anyway.
      next unless custom_domain.valid?

      verification_service = CustomDomainVerificationService.new(domain: custom_domain.domain)
      # Keep the cached aggregate check as the common path so healthy domains
      # do not pay for additional DNS lookups during every daily sweep.
      next if verification_service.has_valid_ssl_certificates?

      # The aggregate check can fail because a stale CNAME names an apex that
      # no longer resolves to Gumroad. Only a missing certificate for a hostname
      # that can currently reach Gumroad should make this sweep queue generation.
      resolving_domains = verification_service.domains_resolving_to_gumroad
      next if resolving_domains.empty?

      unless verification_service.has_valid_ssl_certificates?(domains: resolving_domains)
        custom_domain.reset_ssl_certificate_issued_at!
        custom_domain.generate_ssl_certificate
      end
    end
  end
end
