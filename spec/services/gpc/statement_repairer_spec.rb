require "rails_helper"

RSpec.describe Gpc::StatementRepairer do
  let(:bled) do
    create(
      :recommendation,
      text: "Realizar el reflejo rojo a todos los Eye Evaluations recién nacidos, hasta los 6 2007 meses."
    )
  end
  let(:glued) do
    create(:recommendation, text: "Se debe ofrecer la reducción embrionaria de(Consensus 50 Study ofrecer en centros.")
  end
  let(:eaten) do
    create(:recommendation, text: "Se recomienda el manejo integral posterio2010la dosis inicial de la vacuna.")
  end
  let(:clean) { create(:recommendation, text: "Se recomienda iniciar amoxicilina durante 10 días.") }

  def reply(content)
    ApplicationService::Response.new(
      success: true, errors: nil,
      payload: { content: content.is_a?(String) ? content : content.to_json,
                 input_tokens: 1_000, output_tokens: 60, reasoning_tokens: 0, cost_usd: 0.0004 }
    )
  end

  def stub_reply(content)
    allow(Llm::Completion).to receive(:call) do |**arguments|
      prompts_sent << arguments[:prompt]
      reply(content)
    end
  end

  def prompts_sent
    @prompts_sent ||= []
  end

  it "deletes only the fragments the model names, and marks every statement it read" do
    stub_reply({ "1" => { "remove" => ["Eye Evaluations", "2007"], "damaged" => false } })
    run = create(:generation_run, purpose: "statement_repair")

    result = described_class.call([bled, clean], run: run)

    expect(result.payload).to eq(read: 2, repaired: 1, damaged: 0, refused: 0)
    expect(bled.reload).to have_attributes(
      clean_text: "Realizar el reflejo rojo a todos los recién nacidos, hasta los 6 meses.",
      removed_fragments: ["Eye Evaluations", "2007"], text_damaged: false, repaired_at: be_present
    )
    expect(clean.reload).to have_attributes(clean_text: nil, removed_fragments: [], repaired_at: be_present)
    expect(prompts_sent.sole).to include("1. Realizar el reflejo rojo", "2. Se recomienda iniciar amoxicilina")
    expect(Llm::Completion).to have_received(:call).with(hash_including(role: :verifier))
    expect(run.reload.calls).to eq(1)
  end

  it "marks a statement damaged when the bleed ate letters, and still removes what it can" do
    stub_reply({ "1" => { "remove" => ["2010"], "damaged" => true } })

    expect(described_class.call([eaten]).payload).to include(repaired: 1, damaged: 1)
    expect(eaten.reload).to have_attributes(
      clean_text: "Se recomienda el manejo integral posterio la dosis inicial de la vacuna.", text_damaged: true
    )
  end

  it "marks a statement damaged the model names without anything to remove" do
    stub_reply({ "1" => { "remove" => [], "damaged" => true } })

    described_class.call([eaten])

    expect(eaten.reload).to have_attributes(clean_text: nil, text_damaged: true)
  end

  describe "a reply it refuses, leaving the statement as the parser read it and unread" do
    def refused(statement, fragments)
      stub_reply({ "1" => { "remove" => fragments, "damaged" => true } })
      payload = described_class.call([statement]).payload
      statement.reload
      expect(statement).to have_attributes(
        clean_text: nil, removed_fragments: [], text_damaged: false,
        repaired_at: nil
      )
      payload
    end

    it "when the fragment stands in the text twice, as a year the statement uses might" do
      twice = create(:recommendation, text: "Desde 2007 se vacuna a los recién nacidos hasta los 6 2007 meses.")

      expect(refused(twice, ["2007"])).to include(refused: 1)
    end

    it "when the fragment starts inside a word, or cuts a number" do
      refused(
        create(:recommendation, text: "Vigilar al pacienteof the Royal College cada día en la consulta."),
        ["of the Royal College"]
      )
      refused(create(:recommendation, text: "Administrar 12007 mg al día durante diez días de tratamiento."), ["2007"])
    end

    it "when a fragment is not in the text" do
      expect(refused(bled, ["Pediatric Eye Evaluations"])).to include(refused: 1, repaired: 0, damaged: 0)
    end

    it "when a fragment ends glued to the next word" do
      expect(refused(glued, ["Consensus 50 Study of"])).to include(refused: 1)
    end

    it "when a fragment is too long to be a citation, or they are too much of the statement" do
      refused(clean, ["SIGN #{"x" * described_class::MAX_FRAGMENT_CHARS}"])
      refused(
        create(:recommendation, text: "Se recomienda NICE Clinical Guideline 2019 reposo."),
        ["NICE Clinical Guideline 2019"]
      )
    end
  end

  # Named on the first full run: real words with broken spacing, a meaning-bearing
  # "Solo", the statement's own pointer to a figure.
  it "leaves in a fragment that does not look like a citation" do
    statement = create(
      :recommendation,
      text: "Solo se recomienda en aque llos pacientes (cuadro 7) SIGN 2008 con fiebre."
    )
    stub_reply({ "1" => { "remove" => ["Solo", "aque llos", "(cuadro 7)", "SIGN 2008"] } })

    described_class.call([statement])

    expect(statement.reload).to have_attributes(
      clean_text: "Solo se recomienda en aque llos pacientes (cuadro 7) con fiebre.", removed_fragments: ["SIGN 2008"]
    )
  end

  it "ignores an answer that is not an object" do
    stub_reply({ "1" => "2007" })

    expect(described_class.call([bled]).payload).to include(read: 1, repaired: 0)
    expect(bled.reload.clean_text).to be_nil
  end

  it "tidies the spaces a deletion leaves, keeping line breaks" do
    statement = create(:recommendation, text: "Vigilar la glucosa ( SIGN ) cada 6 horas NICE .\nReferir si persiste.")
    stub_reply({ "1" => { "remove" => %w[SIGN NICE] } })

    described_class.call([statement])

    expect(statement.reload.clean_text).to eq("Vigilar la glucosa () cada 6 horas.\nReferir si persiste.")
  end

  it "fails without touching anything when the model cannot be reached or does not answer in JSON" do
    errors = ActiveModel::Errors.new(Recommendation.new).tap { |e| e.add(:base, "sin conexión") }
    allow(Llm::Completion).to receive(:call).and_return(
      ApplicationService::Response.new(success: false, errors: errors, payload: nil)
    )

    expect(described_class.call([bled])).to be_failure
    stub_reply("no es JSON")
    result = described_class.call([bled])

    expect(result.errors.full_messages).to include("El modelo no devolvió JSON legible")
    expect(bled.reload.repaired_at).to be_nil
  end

  it "batches statements so each call reads a bounded amount of text" do
    long = Array.new(3) { create(:recommendation, text: "Se recomienda #{"vigilar " * 600}") }

    expect(described_class.batches(long + [clean]).map(&:size)).to eq([1, 1, 2])
    expect(described_class.batches([clean, clean]).map(&:size)).to eq([2])
  end
end
