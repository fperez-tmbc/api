# SendGrid API Reference

## Account

| Field | Value |
|-------|-------|
| Company | The Myers Briggs Company |
| Account owner | Sathyan Varadaraj |
| Primary user ID | 1138732 |
| Subuser | TMBCDevelopment (ID: 9145959, dev@themyersbriggs.com) |

## Authentication

```bash
Authorization: Bearer <key>
# Key stored at: ~/GitHub/.tokens/sendgrid
```

## Base URL

```
https://api.sendgrid.com/v3/
```

---

## Authenticated Sending Domains

| Name | Subdomain | Domain | User | Valid |
|------|-----------|--------|------|-------|
| cppelevate | em3639 | themyersbriggs.net | 1138732 | Yes |
| TMBCDevelopment | em7919 | themyersbriggs.net | 9145959 | Yes |

Both use automatic DKIM signing (CNAME-based).

---

## API Keys in Use

| Name | Key ID |
|------|--------|
| claude *(our key)* | WFTqMwrrQa2pR68A2pdhvg |
| SG Website | 4UvKwjkoTXGytne-LT2C4Q |
| D365EmailUser | QO_BuiPRQM2JQ92v170vLg |
| MBTIType Credentials | zITmqxNYRbacjd8dAkmoRA |
| AppInsightsDigest | d7qfYJBhTCyAMBs4zxX0sw |
| Postman | ySAS9utcRGuLwlpPeQX-0Q |
| ElevateWebApi | QeUhWhxLR_idwPeyUM5qRQ |
| MBTIPortal | UZzkuct9STKUcxrZIjhU7Q |
| MBTIOnline - CSAT | 6ZiqVtPbSQ24--dgGsQKXQ |
| SQL Reindexer API | Jt3mUQ7nQ2yEoe8A-P4ARw |
| AX_Companion | YzmBygieRQueSYTM17R3IA |

---

## Dynamic Templates (116 total)

Templates follow the naming pattern: `[App]-[Type]-[locale]`

Locales in use: `en-US`, `fr-FR`, `nl-NL`

### Elevate app templates (sample)

| Template ID | Name |
|-------------|------|
| d-2ed520faba4349c2870a5ed237fa457e | Elevate-PasswordReset-en-US |
| d-f52d742436da46ee982bd6fd03635680 | Elevate-PasswordReset-fr-FR |
| d-4dd93592e21648028ce35eb483a81600 | Elevate-PasswordReset-nl-NL |
| d-ef3d12e444064a95a32b7df118178e9f | Elevate-RespondentPersonalizedContent-en-US |
| d-019d206426c74d079782b49167e112fd | Elevate-RespondentPersonalizedContent-fr-FR |
| d-39a9cf3bc77a4e5d9f17d845218f5f70 | Elevate-RespondentPersonalizedContent-nl-NL |
| d-3a005686ba7040ffa951ac5441879932 | Elevate-SupportMaterialsToRespondent-en-US |
| d-e7392c008bc94344a96db63f6b8796dc | Elevate-SupportMaterialsToRespondent-fr-FR |
| d-38257f36de38481a9f202149665f3aac | Elevate-SupportMaterialsToRespondent-nl-NL |
| d-d0eee53bf742453a873099b9c7214b51 | Elevate-ReportToRespondent-nl-NL |

To list all templates:
```bash
SGKEY=$(cat ~/GitHub/.tokens/sendgrid)
curl -s "https://api.sendgrid.com/v3/templates?generations=dynamic&page_size=100" \
  -H "Authorization: Bearer $SGKEY" | python3 -m json.tool
```

---

## Mail Settings

| Setting | Status |
|---------|--------|
| Event Notification | **Enabled** |
| Address Whitelist | Disabled |
| BCC | Disabled |
| Bounce Purge | Disabled |
| Footer | Disabled |
| Forward Bounce | Disabled |
| Forward Spam | Disabled |
| Plain Content | Disabled |
| Spam Checker | Disabled |

---

## Sending an Email

### Plain email
```bash
SGKEY=$(cat ~/GitHub/.tokens/sendgrid)
curl -s --request POST \
  --url https://api.sendgrid.com/v3/mail/send \
  --header "Authorization: Bearer $SGKEY" \
  --header "Content-Type: application/json" \
  --data '{
    "personalizations": [{"to": [{"email": "recipient@example.com"}]}],
    "from": {"email": "noreply@themyersbriggs.net", "name": "The Myers-Briggs Company"},
    "subject": "Subject here",
    "content": [{"type": "text/plain", "value": "Body here"}]
  }'
```

### Using a dynamic template
```bash
SGKEY=$(cat ~/GitHub/.tokens/sendgrid)
curl -s --request POST \
  --url https://api.sendgrid.com/v3/mail/send \
  --header "Authorization: Bearer $SGKEY" \
  --header "Content-Type: application/json" \
  --data '{
    "personalizations": [{
      "to": [{"email": "recipient@example.com"}],
      "dynamic_template_data": {
        "SITE_NAME": "Elevate"
      }
    }],
    "from": {"email": "noreply@themyersbriggs.net"},
    "template_id": "d-2ed520faba4349c2870a5ed237fa457e"
  }'
```

---

## Common Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| /v3/mail/send | POST | Send email |
| /v3/templates | GET | List dynamic templates |
| /v3/templates/{id} | GET | Get template details |
| /v3/whitelabel/domains | GET | List authenticated domains |
| /v3/api_keys | GET | List API keys |
| /v3/subusers | GET | List subusers |
| /v3/user/profile | GET | Account profile |
| /v3/stats | GET | Global send stats |
| /v3/suppression/bounces | GET | Bounce list |
| /v3/suppression/unsubscribes | GET | Unsubscribe list |
| /v3/suppression/spam_reports | GET | Spam reports |

---

## Notes

- The `TMBCDevelopment` subuser (dev@themyersbriggs.com) has its own sending domain and API keys — used for development/testing.
- The `cppelevate` domain is the production sending domain under the main account.
- No IP pools are configured; shared IP pool is in use.
- Event notifications are enabled — check with the team before modifying the webhook endpoint.
