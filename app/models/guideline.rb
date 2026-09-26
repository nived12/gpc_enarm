class Guideline < ApplicationRecord
  has_many :guideline_sections, -> { order(:position) }, dependent: :destroy, inverse_of: :guideline
  has_many :recommendations, through: :guideline_sections
  has_many :guideline_topics, dependent: :destroy
  has_many :topics, through: :guideline_topics

  # SS is the Secretaría de Salud; the rest are institution acronyms that read the
  # same in any language, so they stay as they are.
  enum :institution,
    { imss: "imss", health_ministry: "ss", issste: "issste",
      dif: "dif", sedena: "sedena", semar: "semar" },
    prefix: :institution

  enum :source, { live_site: "live_site", web_archive: "web_archive" }, prefix: :source

  # How much the ENARM, which examines a general physician, asks of this guideline — read
  # by Questions::SourceScreener. `levels_of_care` would have said it, but the catalog
  # fills it in for only 53 of the 389 guidelines generation draws from.
  enum :enarm_relevance,
    { core: "core", secondary: "secondary", out_of_scope: "out_of_scope" },
    prefix: :relevance

  validates :catalog_key, presence: true, uniqueness: true
  # A catalog key with a prefix we do not know yields a nil institution. Validating it
  # turns that into one recorded failure instead of a NotNullViolation that takes the
  # whole ingestion run down with it.
  validates :institution, presence: true
  validates :source, presence: true
  validates :title, presence: true
  validates :content_hash, presence: true

  # Guidelines state their own shelf life: "Fecha de actualización: de 3 a 5 años a
  # partir de la fecha de ACTUALIZACIÓN", which appears in roughly a third of the
  # archived corpus. Five is the generous end of that range, and being generous is right
  # here — calling a guideline expired that the exam still tests would be the worse error.
  #
  # This is why the live catalog holds nothing older than 2020: when CENETEC was dissolved
  # in 2025 its successor republished only what was still inside this window. The other
  # ~690 guidelines are past it, and Cirugía General exists *only* among them, so expired
  # is a fact to show the student rather than a reason to drop the guideline.
  VALIDITY_YEARS = 5

  scope :current, -> { where(year: oldest_valid_year..) }
  scope :expired, -> { where(year: ...oldest_valid_year) }
  scope :undated, -> { where(year: nil) }

  def self.oldest_valid_year
    Date.current.year - VALIDITY_YEARS
  end

  scope :with_specialty_label, ->(label) { where("specialty_labels @> ?", [label].to_json) }

  # The ENARM examines physicians. A guideline of nursing interventions teaches nursing,
  # and cases written from it ask what a nurse does next.
  scope :for_physicians, -> { where.not("guidelines.title ~* ?", "enfermer[ií]a") }

  # CENETEC republishes an updated guideline under its old number with a new year —
  # IMSS-076-08 became IMSS-076-21 — so an edition is superseded once a newer one of the
  # same institution and number has statements of its own. Generating from both would
  # teach the 2008 answer next to the 2021 one.
  scope :latest_editions, lambda {
    where(<<~SQL.squish)
      NOT EXISTS (
        SELECT 1 FROM guidelines newer
        JOIN guideline_sections ON guideline_sections.guideline_id = newer.id
        JOIN recommendations ON recommendations.guideline_section_id = guideline_sections.id
        WHERE newer.institution = guidelines.institution
          AND split_part(upper(newer.catalog_key), '-', 2) = split_part(upper(guidelines.catalog_key), '-', 2)
          AND newer.year > guidelines.year
      )
    SQL
  }

  # What Questions::SourceScreener reads: a physician's guideline, in its latest edition,
  # with something actionable in it.
  scope :screenable, lambda {
    for_physicians.latest_editions
                  .where(id: GuidelineSection.actionable.joins(:recommendations).select(:guideline_id))
  }

  # What a generation run draws from: the screenable guidelines the ENARM asks about, with
  # a statement screened as a general physician's decision. One not yet screened is left
  # out rather than assumed relevant — the cases the screen was built to stop came from
  # specialist, rehabilitation and administrative guidelines.
  scope :generatable, lambda {
    screenable.where(enarm_relevance: %w[core secondary])
              .where(id: Recommendation.actionable.decision_general_practice.select("guideline_sections.guideline_id"))
  }

  # Screenable guidelines the screen has not finished: never rated, or rated in scope with
  # a statement still unlabelled.
  scope :screening_pending, lambda {
    unlabelled = Recommendation.actionable.where(decision_kind: nil).select("guideline_sections.guideline_id")
    screenable.where(enarm_relevance: nil)
              .or(screenable.where.not(enarm_relevance: "out_of_scope").where(id: unlabelled))
  }

  # IMSS-028-22 → imss. The prefix is the only place the publishing institution
  # appears in the catalog, so it is derived rather than scraped.
  # CENETEC spelled the Secretaría de Salud "S-" before roughly 2016 and "SS-" after,
  # e.g. S-102-08 and SS-102-22 are the same institution and, there, the same guideline.
  CATALOG_KEY_PREFIX_ALIASES = { "s" => "ss" }.freeze

  # Where a student can go and read the guideline.
  #
  # The live site opens the guideline's own page; an archived one opens the Wayback
  # capture rather than the `id_/` raw-bytes form the importer used, because that form
  # serves the PDF without the archive's header saying when it was captured — and the
  # capture date is the honest part.
  def source_url
    source_web_archive? ? catalog_url : document_url
  end

  # Nil when the year never parsed. Unknown is not the same as expired, and a question
  # generated from it should say so rather than imply currency.
  def expires_on
    Date.new(year + VALIDITY_YEARS, 12, 31) if year
  end

  # The topic a case is filed under when the title names several.
  #
  # A troncal's topic comes first. The convocatoria's cross-cutting contexts — Medicina
  # Familiar, Urgencias, Salud Pública — are where a case happens, not what it is about, and
  # their topics match titles by setting ("…en el primer nivel de atención") rather than by
  # subject. They win only when the guideline names no subject of its own.
  #
  # Then the topic that accounts for most of the title: "Síndrome nefrítico agudo en edad
  # pediátrica" is pediatric nephrology before it is adult nephrology.
  def main_topic
    topics.joins(branch: :specialty)
          .reorder(Arel.sql("CASE specialties.kind WHEN 'core' THEN 0 ELSE 1 END"),
            "guideline_topics.relevance DESC", "topics.id"
          )
          .first
  end

  def expired?
    return false if year.nil?

    year < self.class.oldest_valid_year
  end

  def self.institution_from_catalog_key(catalog_key)
    prefix = catalog_key.to_s.split("-").first.to_s.downcase
    institutions.key(CATALOG_KEY_PREFIX_ALIASES.fetch(prefix, prefix))
  end
end
