import os
import boto3
import requests
from flask import Flask, render_template, request, redirect, url_for, flash, jsonify
from werkzeug.utils import secure_filename
from datetime import datetime
from dotenv import load_dotenv
import threading
import time

load_dotenv()

app = Flask(__name__)
app.secret_key = os.getenv("SECRET_KEY", "unieventsecret2024")

PREDICTHQ_API_KEY  = os.getenv("PREDICTHQ_API_KEY", "")
S3_BUCKET_NAME     = os.getenv("S3_BUCKET_NAME", "unievents-media")
AWS_REGION         = os.getenv("AWS_REGION", "us-east-1")
UPLOAD_FOLDER      = "/tmp/uploads"
ALLOWED_EXTENSIONS = {"png", "jpg", "jpeg", "gif", "webp"}

os.makedirs(UPLOAD_FOLDER, exist_ok=True)
s3_client = boto3.client("s3", region_name=AWS_REGION)

_event_cache  = []
_last_fetched = None


def allowed_file(filename):
    return "." in filename and filename.rsplit(".", 1)[1].lower() in ALLOWED_EXTENSIONS


CATEGORY_LABELS = {
    "conferences":     "Conference",
    "expos":           "Expo",
    "concerts":        "Concert",
    "festivals":       "Festival",
    "performing-arts": "Performing Arts",
    "community":       "Community",
    "sports":          "Sports",
    "academic":        "Academic",
}

CATEGORY_IMAGES = {
    "Conference":     "https://images.unsplash.com/photo-1540575467063-178a50c2df87?w=600&q=80",
    "Expo":           "https://images.unsplash.com/photo-1475721027785-f74eccf877e2?w=600&q=80",
    "Concert":        "https://images.unsplash.com/photo-1493225457124-a3eb161ffa5f?w=600&q=80",
    "Festival":       "https://images.unsplash.com/photo-1514525253161-7a46d19cd819?w=600&q=80",
    "Performing Arts":"https://images.unsplash.com/photo-1503095396549-807759245b35?w=600&q=80",
    "Community":      "https://images.unsplash.com/photo-1511578314322-379afb476865?w=600&q=80",
    "Sports":         "https://images.unsplash.com/photo-1461896836934-ffe607ba8211?w=600&q=80",
    "Academic":       "https://images.unsplash.com/photo-1434030216411-0b793f4b4173?w=600&q=80",
}


def parse_predicthq_events(raw):
    events = []
    for ev in raw:
        cat_key   = ev.get("category", "community")
        cat_label = CATEGORY_LABELS.get(cat_key, "General")

        start_raw = ev.get("start", "")
        try:
            dt       = datetime.fromisoformat(start_raw.replace("Z", "+00:00"))
            date_str = dt.strftime("%Y-%m-%d")
            time_str = dt.strftime("%H:%M")
        except Exception:
            date_str = "TBA"
            time_str = "TBA"

        place_hier = ev.get("place_hierarchies", [])
        if place_hier and place_hier[0]:
            venue = place_hier[0][-1]
        else:
            venue = ev.get("country", "Venue TBA")

        labels      = ev.get("labels", [])
        label_str   = ", ".join(labels) if labels else cat_label
        description = (ev.get("description") or
                       f"Join us for this {cat_label.lower()} event. Topics include: {label_str}.")

        img = CATEGORY_IMAGES.get(cat_label,
              "https://images.unsplash.com/photo-1540575467063-178a50c2df87?w=600&q=80")

        events.append({
            "id":          ev.get("id", ""),
            "title":       ev.get("title", "Untitled Event"),
            "date":        date_str,
            "time":        time_str,
            "venue":       venue,
            "description": description,
            "image":       img,
            "url":         f"https://control.predicthq.com/events/{ev.get('id', '')}",
            "category":    cat_label,
        })
    return events


def get_demo_events():
    return [
        {"id":"demo-1","title":"Annual Tech Fest 2024","date":"2024-11-15","time":"10:00",
         "venue":"GIKI Main Auditorium",
         "description":"Pakistan's biggest student-led technology festival featuring hackathons, robotics competitions, and keynote speakers from leading tech companies.",
         "image":"https://images.unsplash.com/photo-1540575467063-178a50c2df87?w=600&q=80",
         "url":"#","category":"Conference"},
        {"id":"demo-2","title":"WES Annual Gala Night","date":"2024-11-22","time":"18:00",
         "venue":"GIKI Sports Complex",
         "description":"Women Engineering Society presents a night of celebration, awards, and networking to honour academic excellence and community service.",
         "image":"https://images.unsplash.com/photo-1511578314322-379afb476865?w=600&q=80",
         "url":"#","category":"Community"},
        {"id":"demo-3","title":"Adventure Club Trekking Trip","date":"2024-12-01","time":"06:00",
         "venue":"Tarbela Lake Trail",
         "description":"GIKI Adventure Club winter trek. Open to all fitness levels. Limited to 40 spots.",
         "image":"https://images.unsplash.com/photo-1551632811-561732d1e306?w=600&q=80",
         "url":"#","category":"Sports"},
        {"id":"demo-4","title":"Project TOPI Blood Drive","date":"2024-12-05","time":"09:00",
         "venue":"GIKI Medical Centre",
         "description":"Join Project TOPI for the semester blood donation drive. Save lives and earn volunteer hours.",
         "image":"https://images.unsplash.com/photo-1615461066841-6116e61058f4?w=600&q=80",
         "url":"#","category":"Community"},
        {"id":"demo-5","title":"AI & ML Workshop Series","date":"2024-12-10","time":"14:00",
         "venue":"CS Department Lab",
         "description":"Hands-on workshops covering Deep Learning, NLP, and MLOps. Conducted by GIKI AI Society.",
         "image":"https://images.unsplash.com/photo-1677442135703-1787eea5ce01?w=600&q=80",
         "url":"#","category":"Academic"},
        {"id":"demo-6","title":"Inter-Society Sports Gala","date":"2024-12-15","time":"08:00",
         "venue":"GIKI Sports Grounds",
         "description":"Semester-end sports competition: cricket, football, volleyball, and badminton.",
         "image":"https://images.unsplash.com/photo-1461896836934-ffe607ba8211?w=600&q=80",
         "url":"#","category":"Sports"},
    ]


def fetch_events_from_api():
    global _event_cache, _last_fetched
    if not PREDICTHQ_API_KEY:
        app.logger.warning("No PredictHQ API key — using demo data.")
        _event_cache  = get_demo_events()
        _last_fetched = datetime.utcnow()
        return

    headers = {"Authorization": f"Bearer {PREDICTHQ_API_KEY}", "Accept": "application/json"}
    params  = {
        "limit":      20,
        "sort":       "start",
        "active.gte": datetime.utcnow().strftime("%Y-%m-%d"),
        "category":   "conferences,expos,concerts,festivals,performing-arts,community",
    }
    try:
        resp = requests.get("https://api.predicthq.com/v1/events/",
                            headers=headers, params=params, timeout=10)
        resp.raise_for_status()
        raw           = resp.json().get("results", [])
        _event_cache  = parse_predicthq_events(raw)
        _last_fetched = datetime.utcnow()
        app.logger.info(f"Fetched {len(_event_cache)} events from PredictHQ.")
    except Exception as e:
        app.logger.error(f"PredictHQ fetch error: {e}")
        if not _event_cache:
            _event_cache = get_demo_events()
        _last_fetched = datetime.utcnow()


def background_fetch_loop():
    while True:
        with app.app_context():
            fetch_events_from_api()
        time.sleep(1800)


@app.route("/")
def index():
    fetch_events_from_api()
    return render_template("index.html", featured=_event_cache[:3],
                           last_fetched=_last_fetched)


@app.route("/events")
def events():
    category = request.args.get("category", "All")
    filtered = ([e for e in _event_cache if e.get("category") == category]
                if category != "All" else _event_cache)
    categories = ["All"] + sorted({e.get("category","General") for e in _event_cache})
    return render_template("events.html", events=filtered, categories=categories,
                           active_category=category, last_fetched=_last_fetched)


@app.route("/upload", methods=["GET", "POST"])
def upload():
    if request.method == "POST":
        if "poster" not in request.files:
            flash("No file selected.", "error")
            return redirect(request.url)
        file = request.files["poster"]
        if file.filename == "":
            flash("No file selected.", "error")
            return redirect(request.url)
        if file and allowed_file(file.filename):
            filename = secure_filename(file.filename)
            tmp_path = os.path.join(UPLOAD_FOLDER, filename)
            file.save(tmp_path)
            s3_key = f"posters/{datetime.utcnow().strftime('%Y%m%d%H%M%S')}_{filename}"
            try:
                s3_client.upload_file(tmp_path, S3_BUCKET_NAME, s3_key,
                                      ExtraArgs={"ContentType": file.content_type})
                flash(f"Poster uploaded! S3 key: {s3_key}", "success")
            except Exception as e:
                flash(f"Upload failed: {str(e)}", "error")
            finally:
                os.remove(tmp_path)
        else:
            flash("Invalid file type. Allowed: png, jpg, jpeg, gif, webp", "error")
        return redirect(url_for("upload"))
    return render_template("upload.html")


@app.route("/health")
def health():
    return jsonify({"status":"healthy",
                    "instance": os.getenv("HOSTNAME","unknown"),
                    "events_cached": len(_event_cache)}), 200


@app.route("/api/events")
def api_events():
    return jsonify({"events":_event_cache,"count":len(_event_cache),
                    "last_fetched":str(_last_fetched)})


if __name__ == "__main__":
    threading.Thread(target=background_fetch_loop, daemon=True).start()
    app.run(host="0.0.0.0", port=5000, debug=False)
