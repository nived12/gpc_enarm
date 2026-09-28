require "rails_helper"

RSpec.describe Recommendation do
  it "requires the text it will be cited for" do
    recommendation = build(:recommendation, text: nil)

    expect(recommendation).not_to be_valid
    expect(recommendation.errors).to be_of_kind(:text, :blank)
  end

  it "requires the grading strip even when it could not be split" do
    expect(build(:recommendation, label: nil)).not_to be_valid
  end

  it "rejects two statements at the same position in one section" do
    section = create(:guideline_section)
    create(:recommendation, guideline_section: section, position: 1)

    expect(build(:recommendation, guideline_section: section, position: 1)).not_to be_valid
  end

  it "reaches its guideline through its section" do
    guideline = create(:guideline)
    recommendation = create(:recommendation, guideline_section: create(:guideline_section, guideline: guideline))

    expect(recommendation.guideline).to eq(guideline)
  end

  describe "the text a reader sees" do
    let(:recommendation) do
      build(
        :recommendation,
        text: "Explorar el reflejo rojo hasta los 6 Pediatric Eye\nEvaluations 2007 meses.",
        clean_text: "Explorar el reflejo rojo hasta los 6 meses.",
        removed_fragments: ["Pediatric Eye Evaluations", "2007"]
      )
    end

    it "is the repaired text when there is one, and the parser's otherwise" do
      expect(recommendation.readable_text).to eq("Explorar el reflejo rojo hasta los 6 meses.")
      expect(build(:recommendation, text: "Se recomienda X.").readable_text).to eq("Se recomienda X.")
    end

    it "is the parser's text, quote included, for a statement marked damaged" do
      recommendation.text_damaged = true

      expect(recommendation.readable_text).to eq(recommendation.text)
      expect(recommendation.readable_quote("6 Pediatric Eye Evaluations 2007 meses"))
        .to eq("6 Pediatric Eye Evaluations 2007 meses")
    end

    it "accepts a quote from either text" do
      expect(recommendation.contains_quote?("hasta los 6 meses")).to be(true)
      expect(recommendation.contains_quote?("hasta los 6 Pediatric Eye Evaluations")).to be(true)
      expect(recommendation.contains_quote?("hasta los 12 meses")).to be(false)
      expect(build(:recommendation, text: "Se recomienda X.").contains_quote?("Se recomienda X")).to be(true)
    end

    it "cuts a quote taken from the parser's text the way the text was cut" do
      expect(recommendation.readable_quote("los 6 Pediatric Eye Evaluations 2007 meses")).to eq("los 6 meses")
      expect(recommendation.readable_quote("el reflejo rojo")).to eq("el reflejo rojo")
      expect(recommendation.readable_quote(nil)).to be_nil
      expect(build(:recommendation).readable_quote("Se recomienda")).to eq("Se recomienda")
    end

    it "cuts a quote next to punctuation the way the text was tidied" do
      bled = build(
        :recommendation, text: "hasta los 6 meses 2007, luego", removed_fragments: ["2007"],
        clean_text: "hasta los 6 meses, luego"
      )

      expect(bled.readable_quote("6 meses 2007, luego")).to eq("6 meses, luego")
    end

    describe ".without" do
      it "finds a fragment across a line break and whatever its case" do
        expect(described_class.without("a SIGN\n2008 b", "sign 2008").squish).to eq("a b")
        expect(described_class.without("a b", "SIGN")).to be_nil
      end

      it "cuts a fragment only where it stands once, clear of its neighbours" do
        expect(described_class.without("Desde 2007 hasta 6 2007 meses", "2007")).to be_nil
        expect(described_class.without("la salud del niño, grado D", "D").squish).to eq("la salud del niño, grado")
        expect(described_class.without("Administrar 200 mg", "20")).to be_nil
      end

      it "cuts bleed glued to a word by a capital or a digit, not through a word" do
        expect(described_class.without("manejo integralThe College y", "The College").squish).to eq("manejo integral y")
        expect(described_class.without("y evitar2019 desarrollo", "2019").squish).to eq("y evitar desarrollo")
        expect(described_class.without("de(Consensus ofrecer", "Consensus of")).to be_nil
        expect(described_class.without("el espectrohite del", "hite")).to be_nil
      end
    end

    it "keeps a damaged statement out of what is generated from" do
      intact = create(:recommendation)
      create(:recommendation, text_damaged: true)

      expect(described_class.intact).to contain_exactly(intact)
    end
  end

  describe "#figure" do
    let(:section) { create(:guideline_section) }

    it "is the guideline figure the statement sends the reader to" do
      image = create(:clinical_image, :stored, guideline_section: section, label: "CUADRO 2")
      recommendation = create(:recommendation, guideline_section: section, text: "Estratificar según el cuadro 2.")

      expect(recommendation.figure).to eq(image)
    end

    it "is nil for a statement that points at no figure" do
      expect(create(:recommendation, guideline_section: section).figure).to be_nil
    end
  end

  describe "#cited_as" do
    it "reads as grade, scale and study" do
      expect(build(:recommendation).cited_as).to eq("A · NICE · Hong K, 2021")
    end

    it "leaves out what the strip did not say" do
      expect(build(:recommendation, citation: nil).cited_as).to eq("A · NICE")
    end

    it "falls back to the strip when none of it could be split" do
      unparsed = build(:recommendation, grade: nil, scale: nil, citation: nil, label: "FUERTE SHRE 2022")

      expect(unparsed.cited_as).to eq("FUERTE SHRE 2022")
    end
  end

  it "selects only statements that say what to do" do
    create(:recommendation, guideline_section: create(:guideline_section, kind: "evidence"))
    actionable = create(:recommendation, guideline_section: create(:guideline_section, kind: "recommendation"))

    expect(described_class.actionable).to eq([actionable])
  end

  it "selects by grading scale" do
    nice = create(:recommendation, scale: "NICE")
    create(:recommendation, scale: "GRADE")

    expect(described_class.with_scale("NICE")).to eq([nice])
  end
end
