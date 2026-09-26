FactoryBot.define do
  factory :recommendation do
    guideline_section
    text { "Se recomienda otorgar educación prenatal para reducir niveles de estrés." }
    label { "A NICE Hong K, 2021" }
    grade { "A" }
    scale { "NICE" }
    citation { "Hong K, 2021" }
    decision_kind { "general_practice" }
    sequence(:position)
  end
end
