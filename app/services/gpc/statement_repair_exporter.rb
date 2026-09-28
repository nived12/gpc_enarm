# Writes what Gpc::StatementRepairer decided to a file another database can apply.
#
# Recommendations are rebuilt on the far side by its own parser (see
# Gpc::CorpusExporter), so no row id travels. A statement is named by its guideline and
# a digest of its text: the same parser reading the same document writes the same text,
# and gpc:reparse already treats the text as a statement's identity. The judgement is
# paid for once, here, and a question quoting the repaired text finds the same text
# there.
module Gpc
  class StatementRepairExporter < ApplicationService
    ATTRIBUTES = %w[clean_text removed_fragments text_damaged].freeze

    def self.digest(text)
      Digest::SHA256.hexdigest(text)
    end

    def initialize(path)
      super()
      @path = path
    end

    def call
      count = 0
      FileUtils.mkdir_p(File.dirname(path))
      Zlib::GzipWriter.open(path) do |file|
        repaired.find_each do |recommendation|
          file.puts(line(recommendation))
          count += 1
        end
      end

      success(path: path, statements: count)
    end

    private

    attr_reader :path

    def repaired
      Recommendation.where.not(repaired_at: nil)
                    .joins(guideline_section: :guideline)
                    .select("recommendations.*, guidelines.catalog_key AS source_catalog_key")
    end

    def line(recommendation)
      recommendation.slice(*ATTRIBUTES).merge(
        "catalog_key" => recommendation.source_catalog_key, "text_digest" => self.class.digest(recommendation.text)
      ).to_json
    end
  end
end
