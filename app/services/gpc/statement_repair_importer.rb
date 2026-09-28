# Applies a file written by Gpc::StatementRepairExporter. A statement is found by its
# guideline and the digest of its text; one this database's parser wrote differently is
# counted as missing and left for gpc:repair_statements to read here.
#
# Run it before Questions::Importer: a question generated from the repaired text quotes
# words the parser's text does not have in that order, and the importer refuses it.
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
          repairs.each { |repair| apply(by_digest.fetch(repair["text_digest"], []), repair, tally) }
        end
      end

      success(tally)
    end

    private

    attr_reader :path

    def statements_of(catalog_key)
      Recommendation.joins(guideline_section: :guideline).where(guidelines: { catalog_key: catalog_key })
                    .group_by { |recommendation| StatementRepairExporter.digest(recommendation.text) }
    end

    # A guideline can repeat a statement word for word in two sections; both get it.
    def apply(recommendations, repair, tally)
      return tally[:missing] += 1 if recommendations.empty?

      Recommendation.where(id: recommendations).update_all(
        **repair.slice(*StatementRepairExporter::ATTRIBUTES).symbolize_keys, repaired_at: Time.current
      )
      tally[:applied] += 1
    end
  end
end
