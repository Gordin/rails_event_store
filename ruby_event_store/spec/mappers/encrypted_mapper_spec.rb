require 'spec_helper'
require 'openssl'

module RubyEventStore
  module Mappers
    TicketTransferred = Class.new(RubyEventStore::Event) do
      def self.encryption_schema
        {
          sender: {
            name: ->(data) { data.dig(:sender, :user_id) },
            email: ->(data) { data.dig(:sender, :user_id) },
          },
          recipient: {
            name: ->(data) { data.dig(:recipient, :user_id) },
            email: ->(data) { data.dig(:recipient, :user_id) },
          }
        }
      end
    end

    TicketCancelled = Class.new(RubyEventStore::Event)

    RSpec.describe EncryptedMapper do
      let(:key_repository) { InMemoryEncryptionKeyRepository.new }
      let(:mapper) { EncryptedMapper.new(key_repository) }

      specify 'decrypts encrypted fields in presence of encryption keys' do
        key_repository.create('ed4e54a5-c15a-4a63-bacb-7d082aec17e2')
        key_repository.create('a4f66b65-687f-46ee-bd66-f39c029ac7bd')

        mapped_event =
          mapper.serialized_record_to_event(
            mapper.event_to_serialized_record(
              TicketTransferred.new(
                event_id: 'b2e5a6cb-624e-4665-a066-382fcf58afdb',
                data: {
                  ticket_id: 'ec694873-e9ff-4632-bf12-6d27b849f87e',
                  sender: {
                    user_id: 'ed4e54a5-c15a-4a63-bacb-7d082aec17e2',
                    name: 'Alice',
                    email: 'alice@universe'
                  },
                  recipient: {
                    user_id: 'a4f66b65-687f-46ee-bd66-f39c029ac7bd',
                    name: 'Bob',
                    email: 'bob@universe',
                  }
                },
                metadata: {
                  correlation_id: 'a185917a-6a49-4837-9ca4-faa6783c3b7a'
                }
              )
            )
          )

        expect(mapped_event.event_id).to eq('b2e5a6cb-624e-4665-a066-382fcf58afdb')
        expect(mapped_event.data).to eq({
          ticket_id: 'ec694873-e9ff-4632-bf12-6d27b849f87e',
          sender: {
            user_id: 'ed4e54a5-c15a-4a63-bacb-7d082aec17e2',
            name: 'Alice',
            email: 'alice@universe'
          },
          recipient: {
            user_id: 'a4f66b65-687f-46ee-bd66-f39c029ac7bd',
            name: 'Bob',
            email: 'bob@universe',
          }
        })
        expect(mapped_event.metadata[:correlation_id]).to eq('a185917a-6a49-4837-9ca4-faa6783c3b7a')
        expect(mapped_event.metadata.size).to eq(1)
      end

      specify 'obfuscates data for missing keys on decryption' do
        key_repository.create('ed4e54a5-c15a-4a63-bacb-7d082aec17e2')
        key_repository.create('a4f66b65-687f-46ee-bd66-f39c029ac7bd')

        record =
          mapper.event_to_serialized_record(
            TicketTransferred.new(
              event_id: 'b2e5a6cb-624e-4665-a066-382fcf58afdb',
              data: {
                ticket_id: 'ec694873-e9ff-4632-bf12-6d27b849f87e',
                sender: {
                  user_id: 'ed4e54a5-c15a-4a63-bacb-7d082aec17e2',
                  name: 'Alice',
                  email: 'alice@universe'
                },
                recipient: {
                  user_id: 'a4f66b65-687f-46ee-bd66-f39c029ac7bd',
                  name: 'Bob',
                  email: 'bob@universe',
                }
              },
              metadata: {
                correlation_id: 'a185917a-6a49-4837-9ca4-faa6783c3b7a'
              }
            )
          )

        key_repository.forget('ed4e54a5-c15a-4a63-bacb-7d082aec17e2')
        mapped_event = mapper.serialized_record_to_event(record)

        expect(mapped_event.event_id).to eq('b2e5a6cb-624e-4665-a066-382fcf58afdb')
        expect(mapped_event.data).to eq({
          ticket_id: 'ec694873-e9ff-4632-bf12-6d27b849f87e',
          sender: {
            user_id: 'ed4e54a5-c15a-4a63-bacb-7d082aec17e2',
            name: ForgottenData::FORGOTTEN_DATA,
            email: ForgottenData::FORGOTTEN_DATA
          },
          recipient: {
            user_id: 'a4f66b65-687f-46ee-bd66-f39c029ac7bd',
            name: 'Bob',
            email: 'bob@universe',
          }
        })
        expect(mapped_event.metadata[:correlation_id]).to eq('a185917a-6a49-4837-9ca4-faa6783c3b7a')
        expect(mapped_event.metadata.size).to eq(1)
      end

      specify 'no-op for events without encryption schema' do
        mapped_event =
          mapper.serialized_record_to_event(
            mapper.event_to_serialized_record(
              TicketCancelled.new(
                event_id: 'b2e5a6cb-624e-4665-a066-382fcf58afdb',
                data: {
                  ticket_id: 'ec694873-e9ff-4632-bf12-6d27b849f87e',
                },
                metadata: {
                  correlation_id: 'a185917a-6a49-4837-9ca4-faa6783c3b7a'
                }
              )
            )
          )

        expect(mapped_event.event_id).to eq('b2e5a6cb-624e-4665-a066-382fcf58afdb')
        expect(mapped_event.data).to eq({ticket_id: 'ec694873-e9ff-4632-bf12-6d27b849f87e'})
        expect(mapped_event.metadata[:correlation_id]).to eq('a185917a-6a49-4837-9ca4-faa6783c3b7a')
        expect(mapped_event.metadata.size).to eq(1)
      end

      specify 'raises error on encryption with missing encryption key' do
        expect do
          mapper.event_to_serialized_record(
            TicketTransferred.new(
              event_id: 'b2e5a6cb-624e-4665-a066-382fcf58afdb',
              data: {
                ticket_id: 'ec694873-e9ff-4632-bf12-6d27b849f87e',
                sender: {
                  user_id: 'ed4e54a5-c15a-4a63-bacb-7d082aec17e2',
                  name: 'Alice',
                  email: 'alice@universe'
                },
                recipient: {
                  user_id: 'a4f66b65-687f-46ee-bd66-f39c029ac7bd',
                  name: 'Bob',
                  email: 'bob@universe',
                }
              },
              metadata: {
                correlation_id: 'a185917a-6a49-4837-9ca4-faa6783c3b7a'
              }
            )
          )
        end.to raise_error(MissingEncryptionKey, "Could not find encryption key for 'ed4e54a5-c15a-4a63-bacb-7d082aec17e2'")
      end

      specify 'does not modify original event' do
        key_repository.create('ed4e54a5-c15a-4a63-bacb-7d082aec17e2')
        key_repository.create('a4f66b65-687f-46ee-bd66-f39c029ac7bd')

        event = TicketTransferred.new(
          event_id: 'b2e5a6cb-624e-4665-a066-382fcf58afdb',
          data: {
            ticket_id: 'ec694873-e9ff-4632-bf12-6d27b849f87e',
            sender: {
              user_id: 'ed4e54a5-c15a-4a63-bacb-7d082aec17e2',
              name: 'Alice',
              email: 'alice@universe'
            },
            recipient: {
              user_id: 'a4f66b65-687f-46ee-bd66-f39c029ac7bd',
              name: 'Bob',
              email: 'bob@universe',
            }
          },
          metadata: {
            correlation_id: 'a185917a-6a49-4837-9ca4-faa6783c3b7a'
          }
        )
        mapper.event_to_serialized_record(event)

        expect(event.data.dig(:sender, :name)).to eq('Alice')
        expect(event.data.dig(:sender, :email)).to eq('alice@universe')
        expect(event.data.dig(:recipient, :name)).to eq('Bob')
        expect(event.data.dig(:recipient, :email)).to eq('bob@universe')
        expect(event.metadata).not_to have_key(:encryption)
      end

      specify 'two cryptograms of the same input and key are not alike' do
        key_repository.create('ed4e54a5-c15a-4a63-bacb-7d082aec17e2')

        record =
          mapper.event_to_serialized_record(
            TicketTransferred.new(
              event_id: 'b2e5a6cb-624e-4665-a066-382fcf58afdb',
              data: {
                ticket_id: 'ec694873-e9ff-4632-bf12-6d27b849f87e',
                sender: {
                  user_id: 'ed4e54a5-c15a-4a63-bacb-7d082aec17e2',
                  name: 'Alice',
                  email: 'alice@universe'
                },
                recipient: {
                  user_id: 'ed4e54a5-c15a-4a63-bacb-7d082aec17e2',
                  name: 'Alice',
                  email: 'alice@universe',
                }
              },
              metadata: {
                correlation_id: 'a185917a-6a49-4837-9ca4-faa6783c3b7a'
              }
            ))
        data = YAML.load(record.data)

        expect(data.dig(:sender, :name)).not_to eq(data.dig(:recipient, :name))
        expect(data.dig(:sender, :email)).not_to eq(data.dig(:recipient, :email))
      end
    end
  end
end
