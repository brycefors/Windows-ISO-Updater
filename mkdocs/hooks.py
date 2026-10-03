import re
from pathlib import Path

from mkdocs.structure.files import File

# Text meant only for readers on GitHub, such as a pointer to this very site.
_GITHUB_ONLY = re.compile(r"<!-- github-only -->.*?<!-- /github-only -->\n?", re.DOTALL)
# The site nav already leads home, so the docs' own back-links are redundant there.
_BACK_LINK = re.compile(r"^\[← Back to README\]\(\.\./README\.md\)[ \t]*\r?\n?", re.MULTILINE)


# LICENSE has no .md extension, so it would only be copied as a raw download.
def on_files(files, config, **kwargs):
    text = (Path(config["docs_dir"]) / "LICENSE").read_text(encoding="utf-8")
    files.append(File.generated(config, "license.md", content=f"# License\n\n```text\n{text.rstrip()}\n```\n"))
    return files


def on_page_markdown(markdown, page, **kwargs):
    markdown = _BACK_LINK.sub("", _GITHUB_ONLY.sub("", markdown))
    if page.file.src_uri == "README.md":
        markdown = markdown.replace("](LICENSE)", "](license.md)")
    return markdown
