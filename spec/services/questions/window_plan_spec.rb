require "rails_helper"

RSpec.describe Questions::WindowPlan do
  let(:internal) { create(:specialty) }
  let(:surgery) { create(:specialty) }

  def guideline_with(count, specialty: nil, **attributes)
    guideline = create(:guideline, **attributes)
    section = create(:guideline_section, guideline: guideline, kind: "recommendation")
    create_list(:recommendation, count, guideline_section: section)
    create(
      :guideline_topic, guideline: guideline,
      topic: create(:topic, branch: create(:branch, specialty: specialty))
    ) if specialty
    guideline
  end

  def plan(**options) = described_class.new(Guideline.generatable, **options).windows.map(&:first)

  # Medicina Interna owns half the corpus, so newest-first alone gave the pilot's first
  # 99 windows almost none from the smaller specialties.
  it "deals the windows out one specialty at a time when asked" do
    first = guideline_with(8, specialty: internal, year: 2024)
    second = guideline_with(8, specialty: internal, year: 2023)
    third = guideline_with(8, specialty: internal, year: 2022)
    cut = guideline_with(16, specialty: surgery, year: 2010)
    loose = guideline_with(8, year: 2009)

    expect(plan).to eq([first, second, third, cut, loose, cut])
    expect(plan(order: "by_specialty")).to eq([first, cut, loose, second, cut, third])
  end

  it "keeps to one specialty, to top it up" do
    guideline_with(8, specialty: internal)
    cut = guideline_with(16, specialty: surgery)

    expect(plan(specialty: surgery)).to eq([cut, cut])
  end

  it "reads an order it does not know as newest first" do
    newer = guideline_with(8, year: 2024)
    older = guideline_with(8, year: 2010)

    expect(plan(order: "random")).to eq([newer, older])
  end

  it "draws only on statements that ask a general physician's decision" do
    guideline = guideline_with(2)
    specialist = create(
      :recommendation, guideline_section: guideline.guideline_sections.first,
      decision_kind: "specialist"
    )
    create(:recommendation, guideline_section: guideline.guideline_sections.first, decision_kind: nil)

    statements = described_class.new(Guideline.generatable).windows.flat_map(&:last)

    expect(statements.size).to eq(2)
    expect(statements).not_to include(specialist)
  end
end
