module RailsEventStoreActiveRecord
  class EventRepositoryReader

    def has_event?(event_id)
      Event.exists?(event_id: event_id)
    end

    def last_stream_event(stream)
      record = EventInStream.where(stream: stream.name).order('position DESC, id DESC').first
      record && build_event_instance(record)
    end

    def read(spec)
      stream = read_scope(spec)

      if spec.batched?
        batch_reader = ->(offset, limit) { stream.offset(offset).limit(limit).map(&method(:build_event_instance)) }
        RubyEventStore::BatchEnumerator.new(spec.batch_size, spec.limit, batch_reader).each
      elsif spec.first?
        record = stream.first
        build_event_instance(record) if record
      elsif spec.last?
        record = stream.last
        build_event_instance(record) if record
      else
        stream.map(&method(:build_event_instance)).each
      end
    end

    def count(spec)
      read_scope(spec).count
    end

    private

    def read_scope(spec)
      if spec.stream.global?
        stream = Event.order(id: order(spec))
        stream = stream.where(event_id: spec.with_ids) if spec.with_ids?
        stream = stream.where(event_type: spec.with_types) if spec.with_types?
        stream = stream.limit(spec.limit) if spec.limit?
        stream = stream.where(start_condition_in_global_stream(spec)) unless spec.head?
        stream
      else
        stream = EventInStream.preload(:event).where(stream: spec.stream.name)
        stream = stream.where(event_id: spec.with_ids) if spec.with_ids?
        stream = stream.joins(:event).where(event_store_events: {event_type: spec.with_types}) if spec.with_types?
        stream = stream.order(position: order(spec), id: order(spec))
        stream = stream.limit(spec.limit) if spec.limit?
        stream = stream.where(start_condition(spec)) unless spec.head?
        stream
      end
    end

    def start_condition(specification)
      event_record = EventInStream.find_by!(event_id: specification.start, stream: specification.stream.name)
      condition = specification.forward? ? 'event_store_events_in_streams.id > ?' : 'event_store_events_in_streams.id < ?'
      [condition, event_record]
    end

    def start_condition_in_global_stream(specification)
      event_record = Event.find_by!(event_id: specification.start)
      condition = specification.forward? ? 'event_store_events.id > ?' : 'event_store_events.id < ?'
      [condition, event_record]
    end

    def order(spec)
      spec.forward? ? 'ASC' : 'DESC'
    end

    def build_event_instance(record)
      record = record.event if EventInStream === record

      RubyEventStore::SerializedRecord.new(
        event_id: record.event_id,
        metadata: record.metadata,
        data: record.data,
        event_type: record.event_type
      )
    end
  end

  private_constant(:EventRepositoryReader)
end
