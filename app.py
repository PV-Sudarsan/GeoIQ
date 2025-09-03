from flask import Flask, request, jsonify, render_template_string, send_file
import boto3
import psycopg2
import os
from io import BytesIO

# S3 client
s3 = boto3.client("s3")
bucket = os.getenv("S3_BUCKET")
region = os.getenv("AWS_DEFAULT_REGION", "us-east-1")

app = Flask(__name__)

@app.route("/up")
def health_check():
    return "200 OK", 200

# Upload page
@app.route("/upload")
def upload_page():
    return render_template_string("""
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>Upload File | FileShare</title>
      <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css">
      <style>
        body { font-family: Arial, sans-serif; background: #f4f7fa; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; }
        .container { text-align: center; background: #fff; padding: 40px; border-radius: 12px; box-shadow: 0 4px 15px rgba(0,0,0,0.1); width: 400px; }
        h2 { color: #333; margin-bottom: 20px; }
        input[type=file] { margin-bottom: 15px; }
        .btn { background: #007bff; color: #fff; border: none; padding: 10px 20px; border-radius: 6px; cursor: pointer; font-size: 14px; }
        .btn:hover { background: #0056b3; }
      </style>
    </head>
    <body>
      <div class="container">
        <h2><i class="fas fa-cloud-upload-alt"></i> Upload File</h2>
        <form action="/upload_success" method="post" enctype="multipart/form-data">
          <input type="file" name="file" required><br>
          <button class="btn" type="submit"><i class="fas fa-upload"></i> Upload</button>
        </form>
      </div>
    </body>
    </html>
    """)

# Upload handler
@app.route("/upload_success", methods=["POST"])
def upload_file():
    try:
        if "file" not in request.files:
            return jsonify({"error": "No file part in the request"}), 400

        file = request.files["file"]
        if file.filename == "":
            return jsonify({"error": "No selected file"}), 400

        # Upload to S3
        s3.upload_fileobj(file, bucket, file.filename)
        url = f"https://{bucket}.s3.{region}.amazonaws.com/{file.filename}"

        # Success HTML
        success_html = f"""
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <title>Upload Success | FileShare</title>
          <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css">
          <style>
            body {{ font-family: Arial, sans-serif; background: #f4f7fa; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; }}
            .container {{ text-align: center; background: #fff; padding: 40px; border-radius: 12px; box-shadow: 0 4px 15px rgba(0,0,0,0.1); width: 500px; }}
            .success-icon {{ font-size: 60px; color: #28a745; margin-bottom: 20px; }}
            h2 {{ color: #333; margin-bottom: 10px; }}
            p {{ color: #666; margin-bottom: 20px; }}
            .url-box {{ display: flex; justify-content: space-between; align-items: center; border: 1px solid #ddd; padding: 10px; border-radius: 8px; margin-bottom: 20px; }}
            .url-text {{ flex: 1; word-break: break-all; text-align: left; }}
            .copy-btn {{ background: #007bff; color: #fff; border: none; padding: 8px 15px; border-radius: 6px; cursor: pointer; }}
            .copy-btn:hover {{ background: #0056b3; }}
            .action-buttons {{ display: flex; justify-content: center; gap: 10px; }}
            .btn {{ padding: 10px 20px; border-radius: 6px; text-decoration: none; font-size: 14px; }}
            .btn-primary {{ background: #007bff; color: #fff; }}
            .btn-secondary {{ background: #6c757d; color: #fff; }}
            .btn-primary:hover {{ background: #0056b3; }}
            .btn-secondary:hover {{ background: #565e64; }}
          </style>
        </head>
        <body>
          <div class="container">
            <div class="success-icon"><i class="fas fa-check-circle"></i></div>
            <h2>File Uploaded Successfully!</h2>
            <p>Your file has been uploaded. Copy the URL below to share it:</p>
            <div class="url-box">
              <div class="url-text" id="url-text">{url}</div>
              <button class="copy-btn" id="copy-btn"><i class="fas fa-copy"></i> Copy</button>
            </div>
            <div class="action-buttons">
              <a href="/upload" class="btn btn-secondary"><i class="fas fa-arrow-left"></i> Back to Upload</a>
              <a href="{url}" target="_blank" class="btn btn-primary"><i class="fas fa-share-alt"></i> Open File</a>
            </div>
          </div>
          <script>
            const copyBtn = document.getElementById("copy-btn");
            const urlText = document.getElementById("url-text").innerText;
            copyBtn.addEventListener("click", () => {{
              navigator.clipboard.writeText(urlText).then(() => {{
                copyBtn.innerHTML = "<i class='fas fa-check'></i> Copied!";
                setTimeout(() => {{
                  copyBtn.innerHTML = "<i class='fas fa-copy'></i> Copy";
                }}, 2000);
              }});
            }});
          </script>
        </body>
        </html>
        """
        return success_html
    except Exception as e:
        return jsonify({"error": str(e)}), 500

# Download file from S3
@app.route("/file/<name>")
def download_file(name):
    try:
        file = BytesIO()
        s3.download_fileobj(bucket, name, file)
        file.seek(0)
        return send_file(file, download_name=name, as_attachment=True)
    except Exception as e:
        return jsonify({"error": str(e)}), 500

# PostgreSQL test
@app.route("/db_test")
def db_test():
    try:
        conn = psycopg2.connect(
            host=os.getenv("DB_HOST"),
            user=os.getenv("DB_USER"),
            password=os.getenv("DB_PASSWORD"),
            dbname=os.getenv("DB_NAME", "postgres"),
            port=os.getenv("DB_PORT", 5432),
        )
        cur = conn.cursor()
        cur.execute("CREATE TABLE IF NOT EXISTS test (id serial PRIMARY KEY, data varchar(100));")
        cur.execute("INSERT INTO test (data) VALUES ('GeoIQ');")
        conn.commit()
        cur.execute("SELECT * FROM test;")
        results = cur.fetchall()
        cur.close()
        conn.close()
        return jsonify({"results": results})
    except Exception as e:
        return jsonify({"error": str(e)}), 500

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=True)
