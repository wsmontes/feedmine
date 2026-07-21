import unittest
import urllib.parse
import xml.etree.ElementTree as ET

from scripts import populate_empty_opml_candidates as subject


def translation_cache(language: str, values: dict[str, str]) -> dict:
    intents = set(subject.TOPIC_INTENTS) | set(subject.PLACE_INTENTS) | {"region"}
    translated = {value: value for value in intents if value}
    translated.update(values)
    return {"translations": {language: translated}}


def query_for(node: ET.Element) -> str:
    parsed = urllib.parse.urlsplit(node.attrib["xmlUrl"])
    return urllib.parse.parse_qs(parsed.query)["q"][0]


class CandidateGenerationTests(unittest.TestCase):
    def test_language_queries_use_translated_topic_and_intents(self):
        root = ET.fromstring("""
            <opml><head><title>Dogs Feeds — Slovenian</title><language>sl</language></head>
            <body><outline text="Dogs" /></body></opml>
        """)
        cache = translation_cache("sl", {"Dogs": "Psi", "news": "novice"})
        countries = {
            "slovenia": {"iso2": "si", "cctld": "si", "use_cctld": True}
        }

        candidates = subject.language_candidates(
            root,
            subject.FEEDS_ROOT / "languages" / "sl" / "dogs.opml",
            countries,
            cache,
        )

        self.assertEqual(len(candidates), 10)
        self.assertEqual(query_for(candidates[0]), '"Psi" site:.si')
        self.assertEqual(query_for(candidates[1]), '"Psi" novice site:.si')
        self.assertEqual(candidates[0].attrib["queryLanguage"], "sl")
        self.assertEqual(candidates[0].attrib["queryScope"], "topic")

    def test_region_queries_include_country_to_disambiguate_place(self):
        root = ET.fromstring("""
            <opml><head><title>Ariana Feeds</title><language>ar</language></head>
            <body /></opml>
        """)
        cache = translation_cache("ar", {"local news": "أخبار محلية", "region": "منطقة"})
        countries = {
            "tunisia": {
                "name": "Tunisia", "native_name": "تونس", "iso2": "tn", "lang": "ar",
                "cctld": "tn", "use_cctld": True,
            }
        }

        candidates = subject.country_candidates(
            root,
            subject.FEEDS_ROOT / "countries" / "tunisia" / "tunisia-ariana.opml",
            countries,
            cache,
        )

        self.assertEqual(len(candidates), 10)
        self.assertEqual(query_for(candidates[0]), "Ariana منطقة site:.tn")
        self.assertEqual(query_for(candidates[1]), "Ariana منطقة site:.tn أخبار محلية")
        self.assertEqual(candidates[0].attrib["queryScope"], "region-country")

    def test_removing_generated_candidates_preserves_editorial_feeds(self):
        root = ET.fromstring("""
            <opml><body><outline text="Feeds">
              <outline title="Editorial" xmlUrl="https://example.com/feed" />
              <outline title="Candidate" xmlUrl="https://example.com/candidate"
                       feedmineCandidate="true" />
            </outline></body></opml>
        """)

        subject.remove_generated(root)

        feeds = root.findall(".//outline[@xmlUrl]")
        self.assertEqual([node.attrib["title"] for node in feeds], ["Editorial"])


if __name__ == "__main__":
    unittest.main()
