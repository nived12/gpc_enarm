# Writes Modo ENARM's best-available versions to a file another database can apply with
# Questions::BestAvailableImporter. A version is named by its case's export_key and its
# original's position, so no row id travels, and the rest of the bank is not in the file:
# a production that already holds every case gets its versions without a full import
# rewriting what reviewers decided there.
module Questions
  class BestAvailableExporter < ApplicationService
    ATTRIBUTES = %w[explanation best_available_verdict best_available_note].freeze
    OPTION_ATTRIBUTES = Exporter::OPTION_ATTRIBUTES

    def initialize(path)
      super()
      @path = path
    end

    def call
      count = 0
      FileUtils.mkdir_p(File.dirname(path))
      Zlib::GzipWriter.open(path) do |file|
        versions.find_each do |version|
          file.puts(line(version))
          count += 1
        end
      end

      success(path: path, versions: count)
    end

    private

    attr_reader :path

    def versions
      Question.where.not(variant_of_id: nil).includes(:answer_options, :clinical_case)
    end

    def line(version)
      version.slice(*ATTRIBUTES).merge(
        "case_key" => version.clinical_case.export_key, "position" => version.position,
        "options" => version.answer_options.map { |option| option.slice(*OPTION_ATTRIBUTES) }
      ).to_json
    end
  end
end
