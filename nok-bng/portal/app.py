from flask import Flask, request, redirect, make_response, render_template
import os

app = Flask(__name__)

USERNAME = os.environ.get("PORTAL_USERNAME")
PASSWORD = os.environ.get("PORTAL_PASSWORD")


@app.route("/login", methods=["GET","POST"])
def login():

    redirect_url = request.args.get("rd", "/")
    if request.method == "POST":

        user = request.form.get("username")
        pwd = request.form.get("password")

        if user == USERNAME and pwd == PASSWORD:

            #resp = make_response(redirect("/"))
            resp = make_response(redirect(redirect_url))
            resp.set_cookie("auth", "ok", httponly=True, max_age=3600)

            return resp
        
        return redirect("/login?error=1")

    return render_template("login.html")


@app.route("/auth")
def auth():

    cookie = request.cookies.get("auth")

    if cookie == "ok":
        return "OK",200

    return "Unauthorized",401


app.run(host="0.0.0.0",port=8080)