# The rest of a guideline's statements, for a model judging or writing why a distractor
# is not the answer: the most instructive distractors are right somewhere else in the
# same guideline, and neither the writer nor the judge can say so without reading it.
module Questions
  class GuidelineContext
    # Enough of the guideline to find where a distractor does apply, without sending a
    # whole anexo for every case.
    STATEMENTS = 40

    # `questions` must all cite a recommendation; the first one decides the guideline.
    def initialize(questions)
      @questions = questions
    end

    def to_s
      cited = questions.map(&:recommendation_id)
      guideline_id = questions.first.recommendation.guideline_section.guideline_id
      Recommendation.actionable.intact.where(guideline_sections: { guideline_id: guideline_id })
                    .where.not(id: cited).order(:id).limit(STATEMENTS)
                    .map { |recommendation| "- #{recommendation.readable_text.squish}" }.join("\n")
    end

    private

    attr_reader :questions
  end
end
