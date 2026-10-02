require "rails_helper"

RSpec.describe Questions::BestAvailableWriter do
  let(:guideline) { create(:guideline) }
  let(:section) { create(:guideline_section, guideline: guideline, kind: "recommendation") }
  let(:cited) do
    create(:recommendation, guideline_section: section, text: "Se recomienda sulfato de magnesio en la eclampsia.")
  end
  let(:clinical_case) do
    create(:clinical_case, guideline: guideline, stem: "Mujer de 27 años, embarazo de 34 semanas.")
  end
  let!(:question) do
    create(
      :question, clinical_case: clinical_case, position: 1, recommendation: cited, explanation: "Previene.",
      text: "¿Cuál es la conducta inicial?", source_quote: "sulfato de magnesio"
    ).tap do |question|
      ["Sulfato de magnesio", "Diazepam intravenoso", "Fenitoína",
"Tomografía de cráneo"].each.with_index(1) do |text, position|
        create(
          :answer_option, question: question, position: position, text: text, correct: position == 1,
          rationale: ("Razón original #{position}." unless position == 1)
        )
      end
    end
  end

  let(:reply) do
    {
      "suitable" => true, "best" => "B", "new_option" => " Haloperidol  intramuscular ",
      "explanation" => "La ideal sería sulfato de magnesio; de las ofrecidas, el diazepam detiene la crisis.",
      "rationales" => { "C" => "Inicio más lento.", "D" => "No trata la crisis.", "new" => "Tampoco la trata." }
    }
  end

  def stub_model(payload, success: true)
    allow(Llm::Completion).to receive(:call).and_return(
      ApplicationService::Response.new(
        success: success, errors: (success ? nil : "sin conexión"),
        payload: { content: payload.is_a?(String) ? payload : payload.to_json,
                   input_tokens: 800, output_tokens: 200, reasoning_tokens: 0, cost_usd: 0.0005 }
      )
    )
  end

  it "keeps the case and the citation, drops the ideal answer and marks the closest one correct" do
    stub_model(reply)
    run = create(:generation_run, purpose: "best_available")

    variant = described_class.call(question, run: run).payload[:variant]

    expect(variant).to have_attributes(
      clinical_case: clinical_case, position: 1, text: question.text, recommendation: cited,
      source_quote: "sulfato de magnesio", variant_of: question,
      explanation: a_string_including("La ideal sería sulfato de magnesio")
    )
    expect(variant.answer_options.map { |option| [option.text, option.correct, option.rationale] }).to eq(
      [
        ["Diazepam intravenoso", true, nil], ["Fenitoína", false, "Inicio más lento."],
        ["Tomografía de cráneo", false, "No trata la crisis."],
        ["Haloperidol intramuscular", false, "Tampoco la trata."]
      ]
    )
    expect(clinical_case.questions.reload).to eq([question])
    expect(run.reload.attempts).to eq(1)
    expect(Llm::Completion).to have_received(:call).with(
      hash_including(role: :generator, prompt: a_string_including("A) Sulfato de magnesio (correcta)", "Previene"))
    )
  end

  it "writes nothing when no remaining option is clearly the best, and remembers not to ask again" do
    stub_model({ "suitable" => false })

    expect(described_class.call(question).payload).to eq(variant: nil)
    expect(question.reload.best_available_variant).to be_nil
    expect(question.best_available_declined_at).to be_present
  end

  it "refuses a choice that is not a distractor, a missing piece, or an option already there" do
    {
      { "best" => "A" } => "no es un distractor",
      { "best" => "Z" } => "no es un distractor",
      { "new_option" => "" } => "Falta la opción nueva",
      { "explanation" => " " } => "Falta la opción nueva",
      { "new_option" => "sulfato de MAGNESIO" } => "repite una de las que ya había"
    }.each do |change, message|
      stub_model(reply.merge(change))

      expect(described_class.call(question).errors.full_messages.first).to include(message)
    end
    expect(question.reload.best_available_variant).to be_nil
  end

  # The original's rationale explains why an option loses to the ideal answer, which the
  # version no longer offers, so it is never carried over.
  it "refuses a version without its own reason for every option left wrong" do
    [reply["rationales"].merge("D" => " "), "ninguna"].each do |rationales|
      stub_model(reply.merge("rationales" => rationales))

      expect(described_class.call(question).errors.full_messages.first).to include("Faltan razones")
    end
  end

  it "fails on an unreadable reply or a failed call, and never writes a second version" do
    stub_model("no es JSON")
    expect(described_class.call(question).errors.full_messages.first).to include("JSON legible")

    stub_model("", success: false)
    expect(described_class.call(question)).to be_failure

    stub_model(reply)
    described_class.call(question)
    expect(described_class.call(question.reload).errors.full_messages.first).to include("ya tiene")
  end

  it "refuses a question without four options or without a cited recommendation" do
    question.update!(recommendation: nil, source_quote: nil)
    expect(described_class.call(question).errors.full_messages.first).to include("recomendación citada")

    question.update!(recommendation: cited)
    question.answer_options.last.destroy!
    expect(described_class.call(question.reload).errors.full_messages.first).to include("cuatro opciones")
  end

  it "asks for English on an English case" do
    clinical_case.update!(locale: "en")
    stub_model({ "suitable" => false })

    described_class.call(question)

    expect(Llm::Completion).to have_received(:call).with(hash_including(prompt: a_string_including("EN INGLÉS")))
  end
end
