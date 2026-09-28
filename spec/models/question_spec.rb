require "rails_helper"

RSpec.describe Question do
  let(:recommendation) do
    create(
      :recommendation, text: "Se recomienda realizar electrocardiograma de 12 derivaciones " \
                                  "en los primeros diez minutos del primer contacto médico."
    )
  end

  describe "the source quote gate" do
    it "accepts a quote copied verbatim from the recommendation" do
      question = build(
        :question, recommendation: recommendation,
        source_quote: "electrocardiograma de 12 derivaciones"
      )

      expect(question).to be_valid
    end

    it "rejects a quote the recommendation does not contain" do
      question = build(
        :question, recommendation: recommendation,
        source_quote: "se recomienda angiografía coronaria inmediata"
      )

      expect(question).not_to be_valid
      expect(question.errors[:source_quote]).to include("no aparece en la recomendación citada")
    end

    it "rejects a quote that is only nearly right" do
      question = build(
        :question, recommendation: recommendation,
        source_quote: "electrocardiograma de 15 derivaciones"
      )

      expect(question).not_to be_valid
    end

    it "accepts a quote whose line break the model wrote as a space" do
      broken = create(
        :recommendation,
        text: "Se deben evitar:\nPicos hiperóxicos mediante la reducción rápida de la FiO2"
      )
      question = build(
        :question, recommendation: broken,
        source_quote: "Se deben evitar: Picos hiperóxicos"
      )

      expect(question).to be_valid
    end

    it "accepts a quote from the repaired text, which the parser's text does not contain" do
      bled = create(
        :recommendation, text: "Se recomienda realizar SIGN 2008 electrocardiograma.",
        clean_text: "Se recomienda realizar electrocardiograma."
      )

      expect(build(:question, recommendation: bled, source_quote: "realizar electrocardiograma")).to be_valid
    end

    it "accepts a quote the model lowercased to fit its own sentence" do
      question = build(
        :question, recommendation: recommendation,
        source_quote: "se recomienda realizar electrocardiograma"
      )

      expect(question).to be_valid
    end

    it "still rejects a paraphrase, which collapsing whitespace does not rescue" do
      broken = create(:recommendation, text: "Se deben evitar:\nPicos hiperóxicos")
      question = build(
        :question, recommendation: broken,
        source_quote: "Se deben prevenir los picos de hiperoxia"
      )

      expect(question).not_to be_valid
    end

    it "allows a question with no quote at all" do
      expect(build(:question, recommendation: recommendation, source_quote: nil)).to be_valid
    end

    it "allows a quote when no recommendation is cited, since there is nothing to check against" do
      expect(build(:question, recommendation: nil, source_quote: "cualquier cosa")).to be_valid
    end
  end

  describe "#correct_option" do
    it "returns the one option marked correct" do
      question = create(:question)
      create(:answer_option, question: question, position: 1, correct: false)
      correct = create(:answer_option, question: question, position: 2, correct: true)

      expect(question.reload.correct_option).to eq(correct)
    end

    it "returns nothing when no option is marked correct" do
      question = create(:question)
      create(:answer_option, question: question, position: 1, correct: false)

      expect(question.reload.correct_option).to be_nil
    end
  end

  describe "#citation" do
    it "delegates to the recommendation" do
      question = build(:question, recommendation: recommendation)

      expect(question.citation).to eq(recommendation.cited_as)
    end

    it "is nothing when no recommendation is cited" do
      expect(build(:question, recommendation: nil).citation).to be_nil
    end
  end

  it "keeps positions unique within a case" do
    question = create(:question, position: 1)
    duplicate = build(:question, clinical_case: question.clinical_case, position: 1)

    expect(duplicate).not_to be_valid
  end
end
