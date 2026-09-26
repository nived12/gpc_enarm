FactoryBot.define do
  factory :guideline do
    sequence(:catalog_key) { |n| "IMSS-#{format("%03d", n)}-22" }
    title { "Atención y cuidados multidisciplinarios en el embarazo" }
    institution { "imss" }
    year { 2022 }
    source { "live_site" }
    external_id { "3079" }
    catalog_url { "https://gpc.salud.gob.mx/DDIMBE" }
    document_url { "https://gpc.salud.gob.mx/DDIMBE/DDIMBE/ContenidoGuia?DocumentoID=3079" }
    levels_of_care { [1, 2] }
    specialty_labels { ["Gineco-Obstetricia"] }
    enarm_relevance { "core" }
    sequence(:content_hash) { |n| Digest::SHA256.hexdigest("guideline-#{n}") }
    ingested_at { Time.current }
  end
end
