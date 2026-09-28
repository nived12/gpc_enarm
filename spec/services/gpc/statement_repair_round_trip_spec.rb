require "rails_helper"

RSpec.describe "Moving statement repairs between databases" do
  let(:path) { Rails.root.join("tmp/test-statement-repairs-#{SecureRandom.hex(4)}.jsonl.gz").to_s }
  let(:guideline) { create(:guideline, catalog_key: "IMSS-363-13") }
  let(:section) { create(:guideline_section, guideline: guideline) }
  let(:text) { "Realizar el reflejo rojo hasta los 6 2007 meses." }

  after { FileUtils.rm_f(path) }

  it "names each repaired statement by its guideline and text, and applies it where both match" do
    create(
      :recommendation, guideline_section: section, text: text,
      clean_text: "Realizar el reflejo rojo hasta los 6 meses.",
      removed_fragments: ["2007"], repaired_at: 1.day.ago
    )
    create(:recommendation, guideline_section: section, repaired_at: 1.day.ago, text_damaged: true)
    create(:recommendation, guideline_section: section)

    expect(Gpc::StatementRepairExporter.call(path).payload).to eq(path: path, statements: 2)

    # The far side: the same guideline, its statements rebuilt by its own parser as new
    # rows, and one statement it read differently.
    Recommendation.delete_all
    rebuilt = create(:recommendation, guideline_section: section, text: text)
    create(:recommendation, guideline_section: section, text: "Otra lectura del parser.")

    result = Gpc::StatementRepairImporter.call(path)

    expect(result.payload).to eq(applied: 1, missing: 1)
    expect(rebuilt.reload).to have_attributes(
      clean_text: "Realizar el reflejo rojo hasta los 6 meses.", removed_fragments: ["2007"],
      text_damaged: false, repaired_at: be_present
    )
  end

  it "refuses a file that is not there" do
    expect(Gpc::StatementRepairImporter.call(path).errors.full_messages).to eq(["No existe #{path}"])
  end
end
