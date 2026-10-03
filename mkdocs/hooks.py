import re

# Text meant only for readers on GitHub, such as a pointer to this very site.
_GITHUB_ONLY = re.compile(r"<!-- github-only -->.*?<!-- /github-only -->\n?", re.DOTALL)
# The site nav already leads home, so the docs' own back-links are redundant there.
_BACK_LINK = re.compile(r"^\[← Back to README\]\(\.\./README\.md\)[ \t]*\r?\n?", re.MULTILINE)


def on_page_markdown(markdown, **kwargs):
    return _BACK_LINK.sub("", _GITHUB_ONLY.sub("", markdown))
