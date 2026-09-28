# Applies a file written by Gpc::StatementRepairExporter. A statement is found by its
# guideline and the digest of its text; one this database's parser wrote differently is
# counted as missing and left for gpc:repair_statements to read here.
module Gpc
  class StatementRepairImporter < ApplicationService
    def initialize(path)
      super()
      @path = path
    end

    def call
      return failure("No existe #{path}") unless File.exist?(path)

      tally = { applied: 0, missing: 0 }
      Zlib::GzipReader.open(path) do |file|
        file.each_line.map do |line|
          JSON.parse(line)
        end.group_by { |repair| repair["catalog_key"] }.each do |key, repairs|
          by_digest = statements_of(key)
          repairs.each { |repair| apply(by_digest[repair["text_digest"]], repair, tally) }
        end
      end

      success(tally)
    end

    private

    attr_reader :path

    def statements_of(catalog_key)
      Recommendation.joins(guideline_section: :guideline).where(guidelines: { catalog_key: catalog_key })
                    .index_by { |recommendation| StatementRepairExporter.digest(recommendation.text) }
    end

    def apply(recommendation, repair, tally)
      return tally[:missing] += 1 if recommendation.nil?

      recommendation.update_columns(
        **repair.slice(*StatementRepairExporter::ATTRIBUTES).symbolize_keys,
                                            repaired_at: Time.current
      )
      tally[:applied] += 1
    end
  end
end
