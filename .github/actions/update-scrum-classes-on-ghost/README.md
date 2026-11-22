# Ghost Scrum class schedules

The scheduled action updates matching HTML and Markdown cards in Ghost pages and posts tagged `#training`. It supports both Mobiledoc and Lexical content.

Use `<!-- SCRUM-CLASS-LIST:START -->` and `<!-- SCRUM-CLASS-LIST:END -->` around the all-classes schedule. For a course-specific schedule, use `<!--SCRUM TRAINING:318-->` and `<!--/SCRUM TRAINING-->`, substituting the Scrum.org course type ID. The older `<!--SCRUM TRAINING-->` all-classes marker remains supported.

Only content between markers in the same card is replaced. HTML cards receive a table; Markdown cards receive a Markdown table. Expired classes are omitted and an empty result clears the old schedule. Search or API errors fail the action instead of replacing a schedule with an empty result.

Run the mocked tests without contacting Ghost:

```powershell
pwsh -NoProfile -File .github\actions\update-scrum-classes-on-ghost\tests\update-scrum-classes.Tests.ps1
pwsh -NoProfile -File .github\actions\update-scrum-classes-on-ghost\tests\update-scrum-classes-invocation.Tests.ps1
```
