require "rails_helper"

RSpec.describe ClinicalCase do
  describe ".in_review_queue" do
    it "holds cases a second opinion found flawed, alongside disputed and unread ones" do
      flawed = create(:clinical_case, verification_verdict: "flawed")
      unread = create(:clinical_case, verification_verdict: nil)
      create(:clinical_case, verification_verdict: "supported")
      create(:clinical_case, verification_verdict: "flawed", status: "retired")

      expect(described_class.in_review_queue).to contain_exactly(flawed, unread)
    end
  end

  describe "#status_after_verdict" do
    it "takes a live case off the bank when the verdict stops supporting it, and nothing else" do
      expect(build(:clinical_case, status: "published").status_after_verdict("flawed")).to eq("draft")
      expect(build(:clinical_case, status: "published").status_after_verdict("supported")).to eq("published")
      expect(build(:clinical_case, status: "draft").status_after_verdict("supported")).to eq("draft")
      expect(build(:clinical_case, status: "retired").status_after_verdict("flawed")).to eq("retired")
    end
  end

  describe ".recheckable_before" do
    it "reads supported and flawed cases verified before the time, never retired ones or later ones" do
      cutoff = Time.zone.parse("2026-09-26 02:00")
      before = cutoff - 1.hour
      supported = create(:clinical_case, verification_verdict: "supported", verified_at: before)
      flawed = create(:clinical_case, verification_verdict: "flawed", verified_at: before)
      create(:clinical_case, verification_verdict: "unsupported", verified_at: before)
      create(:clinical_case, verification_verdict: "supported", verified_at: before, status: "retired")
      create(:clinical_case, verification_verdict: "supported", verified_at: cutoff + 1.minute)

      expect(described_class.recheckable_before(cutoff)).to contain_exactly(supported, flawed)
    end
  end

  describe "#publishable?" do
    it "is true only once a verifier has called it supported" do
      expect(build(:clinical_case, verification_verdict: "supported")).to be_publishable
    end

    it "is false while no verifier has looked at it — silence is not assent" do
      expect(build(:clinical_case, verification_verdict: nil)).not_to be_publishable
    end

    it "is false when the verifier was unsure" do
      expect(build(:clinical_case, verification_verdict: "ambiguous")).not_to be_publishable
    end

    it "is false when the verifier disagreed" do
      expect(build(:clinical_case, verification_verdict: "unsupported")).not_to be_publishable
    end

    it "is false once a person has withdrawn it, even if supported" do
      expect(build(:clinical_case, verification_verdict: "supported", status: "retired")).not_to be_publishable
      expect(build(:clinical_case, verification_verdict: "supported", status: "flagged")).not_to be_publishable
    end
  end

  describe ".publishable" do
    it "returns only the supported cases nobody has withdrawn" do
      supported = create(:clinical_case, verification_verdict: "supported")
      create(:clinical_case, verification_verdict: "supported", status: "retired")
      create(:clinical_case, verification_verdict: "unsupported")
      create(:clinical_case, verification_verdict: nil)

      expect(described_class.publishable).to contain_exactly(supported)
    end
  end

  it "refuses to be published without a supported verdict" do
    kase = build(:clinical_case, verification_verdict: "ambiguous", status: "published")

    expect(kase).not_to be_valid
    expect(kase.errors.of_kind?(:status, :not_supported)).to be(true)
  end

  it "uses the exam's own difficulty vocabulary" do
    expect(described_class.difficulties.keys).to eq(%w[low medium high])
  end

  it "destroys its questions with it" do
    question = create(:question)

    expect { question.clinical_case.destroy }.to change(described_class.all, :count).by(-1)
    expect(Question.exists?(question.id)).to be(false)
  end

  describe "setting" do
    it "is optional: a case nobody has classified yet has an unknown setting" do
      expect(build(:clinical_case, setting: nil)).to be_valid
    end

    it "accepts one of the three cross-cutting contexts" do
      expect(build(:clinical_case, setting: create(:emergency_setting))).to be_valid
    end

    it "refuses a troncal, which is what a case is about, never where it happens" do
      kase = build(:clinical_case, setting: create(:specialty, kind: "core"))

      expect(kase).not_to be_valid
      expect(kase.errors.of_kind?(:setting, :not_cross_cutting)).to be(true)
    end
  end

  describe "areas" do
    let(:internal) { create(:specialty, kind: "core") }
    let(:emergency) { create(:emergency_setting) }
    let(:family) { create(:family_medicine_setting) }

    let!(:internal_in_emergency) { create(:clinical_case, specialty: internal, setting: emergency) }
    let!(:internal_unknown) { create(:clinical_case, specialty: internal, setting: nil) }
    let!(:emergency_in_emergency) { create(:clinical_case, specialty: emergency, setting: emergency) }
    let!(:emergency_in_family) { create(:clinical_case, specialty: emergency, setting: family) }
    let!(:unfiled) { create(:clinical_case, specialty: nil, setting: nil) }

    it "holds a case under its subject and under its setting" do
      expect(described_class.in_area(internal)).to contain_exactly(internal_in_emergency, internal_unknown)
      expect(described_class.in_area(emergency))
        .to contain_exactly(internal_in_emergency, emergency_in_emergency, emergency_in_family)
      expect(described_class.in_area(family)).to contain_exactly(emergency_in_family)
    end

    it "returns each case once when several areas are asked for together" do
      cases = described_class.in_area([internal, emergency])

      expect(cases.to_a.size).to eq(4)
      expect(cases.count).to eq(4)
    end

    it "accepts ids as well as rows" do
      expect(described_class.in_area([family.id])).to contain_exactly(emergency_in_family)
    end

    it "counts a case once in each area it belongs to, and once only when subject and setting agree" do
      expect(described_class.count_by_area).to eq(internal.id => 2, emergency.id => 3, family.id => 1)
    end

    it "leaves out a case that has neither subject nor setting" do
      expect(described_class.by_area.distinct.pluck(:id)).not_to include(unfiled.id)
    end
  end
end
