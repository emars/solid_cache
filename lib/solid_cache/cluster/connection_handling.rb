require "solid_cache/maglev_hash"

module SolidCache
  class Cluster
    module ConnectionHandling
      attr_reader :async_writes, :shards, :database_shards

      def initialize(options = {})
        super(options)
        @shards = options.delete(:shards) || SolidCache.all_shard_keys || [nil]
        @database_shards = @shards.to_h { |shard| [ SolidCache.shard_databases[shard], shard ] }
        @async_writes = options.delete(:async_writes)
      end

      def writing_all_shards
        return enum_for(:writing_all_shards) unless block_given?

        shards.each do |shard|
          with_shard(shard) do
            async_if_required { yield }
          end
        end
      end

      def writing_across_shards(list:, trim: false)
        across_shards(list:) do |list|
          async_if_required do
            result = yield list
            trim(list.size) if trim
            result
          end
        end
      end

      def reading_across_shards(list:)
        across_shards(list:) { |list| yield list }
      end

      def writing_shard(normalized_key:, trim: false)
        with_shard(shard_for_normalized_key(normalized_key)) do
          async_if_required do
            result = yield
            trim(1) if trim
            result
          end
        end
      end

      def reading_shard(normalized_key:)
        with_shard(shard_for_normalized_key(normalized_key)) { yield }
      end

      private
        def with_shard(shard)
          if shard
            Record.connected_to(shard: shard) { yield }
          else
            yield
          end
        end

        def across_shards(list:)
          in_shards(list).map do |shard, list|
            with_shard(shard) { yield list }
          end
        end

        def in_shards(list)
          if shards.count == 1
            { shards.first => list }
          else
            list.group_by { |value| shard_for_normalized_key(value.is_a?(Hash) ? value[:key] : value) }
          end
        end

        def shard_for_normalized_key(normalized_key)
          return shards.first if shards.count == 1

          database = consistent_hash.node(normalized_key)
          database_shards[database]
        end

        def consistent_hash
          return nil if shards.count == 1
          @consistent_hash ||= MaglevHash.new(database_shards.keys)
        end

        def async_if_required
          if async_writes
            async { yield }
          else
            yield
          end
        end
    end
  end
end