require "rails_helper"

RSpec.describe Questions::Prompt do
  let(:guideline) { create(:guideline, title: "Diagnóstico del síndrome coronario agudo") }
  let(:ecg) { build(:recommendation, text: "Se recomienda realizar\nelectrocardiograma de 12 derivaciones.") }
  let(:aspirin) { build(:recommendation, text: "Se recomienda iniciar aspirina 300 mg.") }

  def prompt(recommendations = [ecg, aspirin], **options)
    described_class.new(guideline, recommendations, **options).to_s
  end

  it "asks why each distractor is wrong, politely and from the recommendations alone" do
    expect(prompt).to include(described_class::RATIONALE_INSTRUCTIONS, "\"rationale\"")
    expect(described_class::RATIONALE_INSTRUCTIONS).to include("no inventes", "reprendas", "no se recomienda")
  end

  it "numbers the statements it is handed, in order, so the model can cite them by number" do
    expect(prompt).to include(
      "1. Se recomienda realizar electrocardiograma de 12 derivaciones.\n2. Se recomienda iniciar aspirina 300 mg."
    )
    expect(prompt).to include('"Diagnóstico del síndrome coronario agudo"')
  end

  # Case 250 of the pilot ended its vignette with its own question.
  it "keeps the question out of the vignette" do
    expect(prompt).to include(described_class::STEM_INSTRUCTIONS)
    expect(described_class::STEM_INSTRUCTIONS).to include("nunca con\nuna pregunta", "What is")
  end

  # §9.1 of the convocatoria: the three cross-cutting contexts are where a case happens.
  it "sets the case where the exam sets it" do
    expect(prompt).to include("medicina\nfamiliar en el primer nivel, un servicio de urgencias")
    expect(prompt).to include("No sitúes el caso en una sala")
  end

  it "asks for the setting it chose as a fixed code, in the JSON beside the stem" do
    expect(prompt).to include("family_medicine, emergency, public_health")
    expect(prompt).to include('{"cases":[{"stem":"...","setting":"family_medicine|emergency|public_health",')
  end

  describe "how much of the patient the vignette carries" do
    it "asks for a whole-patient vignette and three questions on a full workup" do
      text = prompt(detail: :full_workup)

      expect(text).to include("paciente COMPLETO", "Signos vitales COMPLETOS", "3 preguntas")
    end

    it "asks for a short vignette and two questions when focused, still with vitals and an exam" do
      expect(prompt(detail: :focused)).to include(
        "breve y centrada", "2 preguntas", "signos vitales con unidades", "exploración física dirigida"
      )
    end

    it "writes two full workups for every focused case" do
      expect(Array.new(6) { |index| described_class.detail_for(index) })
        .to eq(%i[full_workup full_workup focused] * 2)
    end
  end

  # Each of these made a validation-batch item easier than the real exam.
  describe "what a question may not do" do
    it "forbids asking for what the vignette says, other patients, repeats and giveaways" do
      expect(prompt).to include(
        "Nunca pregunta por un dato", "Trata sobre ESTE paciente", "no repitas la misma pregunta",
        "no contiene palabras que delaten"
      )
    end

    # From the first 500-call chunk: an answer right for another patient, specialist
    # detail and administrative trivia all passed a verifier that only reads the citation.
    it "asks for the best choice for this patient, at a general physician's level" do
      expect(prompt.squish).to include(
        "la mejor conducta para ESTE paciente", "lo que un médico general debe saber y decidir",
        "detalles de subespecialidad", "datos administrativos", "Ningún distractor puede ser también correcto",
        "ninguna de las anteriores"
      )
    end

    it "asks for distractors of one kind and length that a physician would consider" do
      expect(prompt).to include("la correcta no es la más larga", "algo que un médico consideraría")
    end

    it "falls back to focused rather than trusting an unknown detail level" do
      expect(prompt(detail: :novela)).to include("breve y centrada")
    end
  end

  describe "language" do
    it "says nothing about language for a Spanish case" do
      expect(prompt).not_to include("EN INGLÉS")
    end

    it "asks for English, keeping the quote in Spanish so the citation gate still holds" do
      expect(prompt(locale: "en")).to include("EN INGLÉS", "cita textual se queda en español")
    end
  end

  # The statements themselves say "(algoritmo 1)", and the pilot wrote a correct option
  # reading "iniciar tamizaje mediante el Algoritmo 1".
  it "forbids pointing at the guideline's figures, which the student does not see" do
    expect(prompt).to include("no los ve mientras responde")
  end
end
