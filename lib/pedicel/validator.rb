require 'dry-validation'
require 'base64'
require 'openssl'

module Pedicel
  # Validations for Apple Pay Payment Token and associated data:
  # https://developer.apple.com/library/content/documentation/PassKit/Reference/PaymentTokenJSON/PaymentTokenJSON.html
  # This purposefully only does syntactic validation (as opposed to semantic).
  module Validator

    module Predicates
      include Dry::Logic::Predicates

      CUSTOM_PREDICATE_ERRORS = {
        base64?:          'must be base64',
        hex?:             'must be hex',
        pan?:             'must be a pan',
        yymmdd?:          'must be formatted YYMMDD',
        ec_public_key?:   'must be an EC public key',
        pkcs7_signature?: 'must be a PKCS7 Signature',
        eci?:             'must be an ECI',
        hex_sha256?:      'must be a hex-encoded SHA256',
        base64_sha256?:   'must be a base64-encoded SHA256',
      }.freeze

      # Support Ruby 2.3, but use the faster #match? when available.
      match_b = String.new.respond_to?(:match?) ? lambda{|s, re| s.match?(re)} : lambda{|s, re| !!(s =~ re)}

      predicate(:base64?) do |x|
        str?(x) &&
          match_b.(x, /\A[=A-Za-z0-9+\/]*\z/) && # allowable chars
          x.length.remainder(4).zero? && # multiple of 4
          !match_b.(x, /=[^$=]/) && # may only end with ='s
          !match_b.(x, /===/) # at most 2 ='s
      end

      # We should figure out how strict we should be. Hopefully we can discard
      # the above base64? predicate and use the following simpler one:
      #predicate(:strict_base64?) { |x| !!Base64.strict_decode64(x) rescue false }

      predicate(:base64_sha256?) { |x| base64?(x) && Base64.decode64(x).length == 32 }

      predicate(:hex?) { |x| str?(x) && match_b.(x, /\A[a-f0-9]*\z/i) }

      predicate(:hex_sha256?) { |x| hex?(x) && x.length == 64 }

      predicate(:pan?) { |x| str?(x) && match_b.(x, /\A[1-9][0-9]{11,18}\z/) }

      predicate(:yymmdd?) { |x| str?(x) && match_b.(x, /\A\d{6}\z/) }

      predicate(:eci?) { |x| str?(x) && match_b.(x, /\A\d{2}\z/) }

      predicate(:ec_public_key?) { |x| base64?(x) && OpenSSL::PKey::EC.new(Base64.decode64(x)).check_key rescue false }

      predicate(:pkcs7_signature?) { |x| base64?(x) && !!OpenSSL::PKCS7.new(Base64.decode64(x)) rescue false }
    end

    TokenSchema = Dry::Validation.Schema do
      configure do
        # NOTE: This option removes/sanitizes hash element not mentioned/tested.
        # Hurray for good documentation.
        config.input_processor = :json

        # In theory, I would guess that :strict below would cause a failure if
        # untested keys were encountered, however this appears to not be the
        # case. Anyways, it's (of course) not documented.
        # config.hash_type = :strict

        predicates(Predicates)
        def self.messages
          super.merge(en: { errors: Predicates::CUSTOM_PREDICATE_ERRORS })
        end
      end

      required(:data).filled(:str?, :base64?)

      required(:header).schema do
        optional(:applicationData).filled(:str?, :hex?, :hex_sha256?)

        optional(:ephemeralPublicKey).filled(:str?, :base64?, :ec_public_key?)

        optional(:wrappedKey).filled(:str?, :base64?)

        rule('ephemeralPublicKey xor wrappedKey': [:ephemeralPublicKey, :wrappedKey]) do |e, w|
          e.filled? ^ w.filled?
        end

        required(:publicKeyHash).filled(:str?, :base64?, :base64_sha256?)

        required(:transactionId).filled(:str?, :hex?)
      end

      required(:signature).filled(:str?, :base64?, :pkcs7_signature?)

      required(:version).filled(:str?, included_in?: %w[EC_v1 RSA_v1])
    end

    TokenDataSchema = Dry::Validation.Schema do
      configure do
        predicates(Predicates)
        def self.messages
          super.merge(en: { errors: Predicates::CUSTOM_PREDICATE_ERRORS })
        end
      end

      required('applicationPrimaryAccountNumber').filled(:str?, :pan?)

      required('applicationExpirationDate').filled(:str?, :yymmdd?)

      required('currencyCode').filled(:str?, format?: /\A[0-9]{3}\z/)

      required('transactionAmount').filled(:int?)

      optional('cardholderName').filled(:str?)

      required('deviceManufacturerIdentifier').filled(:str?, :hex?)

      required('paymentDataType').filled(:str?, included_in?: %w[3DSecure EMV])

      required('paymentData').schema do
        optional('onlinePaymentCryptogram').filled(:str?, :base64?)
        optional('eciIndicator').filled(:str?, :eci?)

        optional('emvData').filled(:str?, :base64?)
        optional('encryptedPINData').filled(:str?, :hex?)
      end

      rule('paymentDataType affects paymentData': [:paymentDataType, [:paymentData, :onlinePaymentCryptogram]]) do |t, cryptogram|
        t.eql?('3DSecure') > cryptogram.filled?
      end
    end

    class Base
      class Error < StandardError; end

      def validate
        @validation = @schema.call(@input)

        raise Error if @validation.failure?

        true
      end

      def valid?
        validate
      rescue Error
        false
      end

      def errors
        valid? unless @validation

        @validation.errors
      end
    end

    class Token < Base
      def initialize(input)
        @input = input
        @schema = TokenSchema
      end
    end

    class TokenData < Base
      def initialize(input)
        @input = input
        @schema = TokenDataSchema
      end
    end
  end
end
