require "rails_helper"

RSpec.describe Pearl do
  def pearl(text)
    described_class.for(build(:recommendation, text: text))
  end

  describe ".for" do
    it "hides the first dose, duration or threshold, as a literal span of the statement" do
      subject = pearl("Se recomienda indicar rt-PA intravenoso a 0.9 mg/kg con un bolo inicial en 1 minuto.")

      expect(subject.answer).to eq("0.9 mg/kg")
      expect(subject.before + subject.answer + subject.after).to eq(subject.recommendation.text)
    end

    it "passes over an aside in parentheses and a study's statistic" do
      expect(pearl("Se sugiere tenecteplasa (máximo 25 mg) en bolo durante 5 minutos.").answer).to eq("5 minutos")
      expect(pearl("Los AINE dieron más efectos (RR 2.5, IC 95% 1.2 a 5.2); vigilar 12 semanas.").answer)
        .to eq("12 semanas")
    end

    it "otherwise hides the action recommended, up to the first clause break" do
      subject = pearl("En toda mujer Rh negativo se debe solicitar prueba de Coombs indirecto para confirmar.")

      expect(subject.answer).to eq("solicitar prueba de Coombs indirecto")
    end

    it "stops before a conjunction the eight-word cut leaves dangling" do
      expect(pearl("Se recomienda promover una buena higiene dental y oral y bucal siempre bien.").answer)
        .to eq("promover una buena higiene dental y oral")
    end

    it "is nothing when the action is only grammar, a single word, or missing" do
      expect(pearl("Se recomienda que el personal de salud promueva el cepillado.")).to be_nil
      expect(pearl("Se recomienda vigilar, con cuidado, la evolución clínica.")).to be_nil
      expect(pearl("La mayoría de los pacientes mejora sin tratamiento específico alguno.")).to be_nil
    end
  end

  describe ".pool" do
    let(:kase) { create(:published_case, questions_count: 1) }
    let(:section) { kase.questions.first.recommendation.guideline_section }

    def statement(text = "Se recomienda iniciar amoxicilina durante 10 días en la otitis media aguda.", **attributes)
      create(:recommendation, guideline_section: section, text: text, **attributes)
    end

    it "keeps graded, actionable statements of dated guidelines with published cases" do
      good = statement

      expect(described_class.pool).to include(good)
    end

    it "leaves out ungraded, figure-bound, too long and non-actionable statements" do
      ungraded = statement(grade: nil)
      figure = statement("Se recomienda clasificar la gravedad con la escala de la guía, ver cuadro 2 del anexo.")
      long = statement("Se recomienda #{"vigilar la evolución clínica " * 15}")
      evidence = create(
        :recommendation, text: "Se recomienda iniciar amoxicilina durante 10 días en la otitis media aguda.",
        guideline_section: create(:guideline_section, guideline: kase.guideline, kind: "evidence")
      )

      expect(described_class.pool).not_to include(ungraded, figure, long, evidence)
    end

    it "reads the repaired text, and leaves out a statement the bleed cut letters from" do
      repaired = statement(
        "Se recomienda iniciar amoxicilina durante 10 SIGN 2008 días en la otitis media aguda.",
        clean_text: "Se recomienda iniciar amoxicilina durante 10 días en la otitis media aguda."
      )
      damaged = statement(text_damaged: true)
      long_until_repaired = statement(
        "Se recomienda vigilar. #{"Scottish Intercollegiate " * 20}",
        clean_text: "Se recomienda vigilar la evolución clínica en la consulta."
      )

      expect(described_class.pool).to include(repaired, long_until_repaired)
      expect(described_class.pool).not_to include(damaged)
      expect(described_class.for(repaired).answer).to eq("10 días")
    end

    it "leaves out guidelines with no published case, and undated ones" do
      draft = create(
        :recommendation,
        text: "Se recomienda iniciar amoxicilina durante 10 días en la otitis media aguda."
      )
      kase.guideline.update!(year: nil)

      expect(described_class.pool).not_to include(draft, statement)
    end
  end
end
