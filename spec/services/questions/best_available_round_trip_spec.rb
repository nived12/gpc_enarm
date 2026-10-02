require "rails_helper"

# Production already holds every case; the versions travel on their own so a full import
# never rewrites what reviewers decided there.
RSpec.describe "best-available versions export and import" do
  let(:path) { Rails.root.join("tmp/spec-best-available-#{SecureRandom.hex(4)}.jsonl.gz").to_s }

  after { FileUtils.rm_f(path) }

  it "adds a version where its original has none, updates the verdict where it has one, and skips unknown cases" do
    kase = create(:published_case, questions_count: 2, best_available: true)
    gone = create(:published_case, questions_count: 1, best_available: true)
    first, second = kase.questions.map(&:best_available_variant)
    first.update!(best_available_verdict: "disputed", best_available_note: "Otra es mejor.")

    expect(Questions::BestAvailableExporter.call(path).payload).to include(versions: 3)

    # The far side: it has this case without its second version, an older verdict on the
    # first, its own edit to an original, and not the other case at all.
    first.update!(best_available_verdict: nil, best_available_note: nil)
    second.destroy!
    gone.destroy!
    kase.questions.first.update!(text: "Texto revisado en producción.")

    result = Questions::BestAvailableImporter.call(path)

    expect(result.payload).to eq(created: 1, updated: 1, missing: 1)
    expect(first.reload).to have_attributes(best_available_verdict: "disputed", best_available_note: "Otra es mejor.")
    restored = kase.questions.second.reload.best_available_variant
    expect(restored).to have_attributes(best_available_verdict: "supported", position: 2)
    expect(restored.answer_options.map(&:text))
      .to eq(["Troponina I", "Radiografía de tórax", "Ecocardiograma", "Gasometría arterial"])
    expect(kase.questions.first.reload.text).to eq("Texto revisado en producción.")
  end

  it "refuses a file that is not there" do
    expect(Questions::BestAvailableImporter.call(path).errors.full_messages.first).to include("No existe")
  end
end
