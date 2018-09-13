module RubyEventStore
  module Mappers
    class ForgottenData
      include Enumerable

      def initialize(string = FORGOTTEN_DATA)
        @string = string
      end

      def inspect
        @string
      end

      alias :to_s :inspect

      def ==(other)
        @string == other
      end

      def to_a
        []
      end

      def to_h
        {}
      end

      def each
        if block_given?
          self
        else
          enum_for(:each)
        end
      end

      def empty?
        true
      end

      def blank?
        true
      end

      def present?
        false
      end

      def size
        0
      end

      alias :count :size

      def method_missing(m, *args, &blk)
        self
      end

      def respond_to_missing?(method_name, include_private = false)
        true
      end

      FORGOTTEN_DATA = 'FORGOTTEN_DATA'.freeze
    end

    class EncryptionKey
      def initialize(cipher:, iv:, key:, identifier:)
        @cipher = cipher
        @iv = iv
        @key = key
        @identifier = identifier
      end

      def encrypt(message, iv: nil)
        crypto = OpenSSL::Cipher.new(cipher)
        crypto.encrypt
        crypto.iv = iv || self.iv
        crypto.key = key
        crypto.update(message) + crypto.final
      end

      def decrypt(message, iv: nil)
        crypto = OpenSSL::Cipher.new(cipher)
        crypto.decrypt
        crypto.iv = iv || self.iv
        crypto.key = key
        (crypto.update(message) + crypto.final).force_encoding("UTF-8")
      end

      attr_reader :cipher, :iv, :key, :identifier
    end

    class InMemoryEncryptionKeyRepository
      DEFAULT_CIPHER = 'aes-256-cbc'

      def initialize
        @keys = {}
      end

      def key_of(identifier, cipher: DEFAULT_CIPHER)
        @keys[[identifier, cipher]]
      end

      def create(identifier, cipher: DEFAULT_CIPHER)
        crypto = OpenSSL::Cipher.new(cipher)
        crypto.encrypt
        @keys[[identifier, cipher]] = EncryptionKey.new(
          identifier: identifier,
          cipher: cipher,
          iv: crypto.random_iv,
          key: crypto.random_key
        )
      end

      def forget(identifier)
        @keys = @keys.reject { |(id, _), _| id == identifier }
      end

      def delete_all
        @keys = {}
      end
    end

    MissingEncryptionKey = Class.new(StandardError)

    class EncryptedMapper
      def initialize(key_repository, serializer: YAML)
        @key_repository = key_repository
        @serializer = serializer
      end

      def event_to_serialized_record(domain_event)
        metadata = {}
        domain_event.metadata.each do |k, v|
          metadata[k] = v
        end

        encryption_schema = domain_event.class.respond_to?(:encryption_schema) && domain_event.class.encryption_schema
        encryption_metadata_ = encryption_metadata(domain_event.data, encryption_schema)

        data = deep_dup(domain_event.data)
        encrypt_data(data, encryption_metadata_)

        SerializedRecord.new(
          event_id: domain_event.event_id,
          metadata: serializer.dump(metadata.merge(encryption: encryption_metadata_)),
          data: serializer.dump(data),
          event_type: domain_event.class.to_s
        )
      end

      def serialized_record_to_event(record)
        metadata = serializer.load(record.metadata)
        data = serializer.load(record.data)
        encryption_metadata = metadata.delete(:encryption)

        Object.const_get(record.event_type).new(
          event_id: record.event_id,
          data: deserialize_data(data, encryption_metadata),
          metadata: metadata,
        )
      end

      protected

      attr_reader :key_repository, :serializer

      def prepare_cipher(cipher_)
        cipher = OpenSSL::Cipher.new(cipher_)
        cipher.encrypt
        cipher
      end

      def deep_dup(hash)
        duplicate = hash.dup
        duplicate.each do |k, v|
          duplicate[k] = v.instance_of?(Hash) ? deep_dup(v) : v
        end
        duplicate
      end

      def encryption_metadata(data, schema)
        return unless schema
        schema.inject({}) do |acc, (key, value)|
          case value
          when Hash
            acc[key] = encryption_metadata(data, value)
          when Proc
            key_identifier = value.call(data)
            encryption_key = key_repository.key_of(key_identifier)
            raise MissingEncryptionKey.new("Could not find encryption key for '#{key_identifier}'") unless encryption_key
            cipher = prepare_cipher(encryption_key.cipher)
            acc[key] = [
              {
                cipher: encryption_key.cipher,
                iv: cipher.random_iv,
                identifier: key_identifier,
              }
            ]
          end
          acc
        end
      end

      def encrypt_data(data, metadata)
        metadata.each do |key, value|
          encrypt_attribute(data, key, value)
        end if metadata
      end

      def encrypt_attribute(data, attribute, meta)
        case meta
        when Array
          spec = meta.first
          encryption_key = key_repository.key_of(spec.fetch(:identifier))
          encryption_key.encrypt(serializer.dump(data.fetch(attribute)), iv: spec.fetch(:iv))
        when Hash
          meta.inject(data.fetch(attribute)) do |acc, (key, value)|
            acc[key] = encrypt_attribute(acc, key, value)
            acc
          end
        end
      end

      def deserialize_data(data, encryption_data)
        if encryption_data
          deep_dup(data).tap do |decrypted_data|
            decrypt_data(decrypted_data, encryption_data)
          end
        else
          data.inject({}) do |acc, (key, value)|
            if value.is_a?(Hash)
              acc[key] = deserialize_data(value, encryption_data)
            else
              acc[key] = value
            end
            acc
          end
        end
      end

      def decrypt_data(data, metadata)
        metadata.each do |key, value|
          decrypt_attribute(data, key, value, key_repository)
        end
      end

      def decrypt_attribute(data, attribute, meta, key_repository)
        data[attribute] =
          case meta
          when Array
            cryptogram = data[attribute]
            return nil unless cryptogram
            spec = meta.first
            encryption_key = key_repository.key_of(spec.fetch(:identifier), cipher: spec.fetch(:cipher))
            if encryption_key
              decrypt_and_decode_value(cryptogram, encryption_key, spec.fetch(:iv))
            else
              ForgottenData.new
            end
          when Hash
            meta.inject(data[attribute]) do |acc, (key, value)|
              acc[key] = decrypt_attribute(acc, key, value, key_repository)
              acc
            end
          else
            data.fetch(attribute)
          end
      end

      def decrypt_and_decode_value(cryptogram, key, iv)
        serializer.load(key.decrypt(cryptogram, iv: iv))
      rescue OpenSSL::Cipher::CipherError
        ForgottenData.new
      end
    end
  end
end