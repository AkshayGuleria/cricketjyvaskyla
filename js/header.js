// JavaScript for Header

var pageUrl = window.location.href;
urlSplit=pageUrl.split("/");
lenUrl=urlSplit.length;
pageName = urlSplit[lenUrl-1];

document.write('<div id="header">');
document.write('<div id="headercontent">');
document.write('<h1 id="sitename" style="margin:2px 5px 5px 230px; padding: 2px 10px 0px 10px; background-image:url(images/title.png) ;">JYV&Auml;SKYL&Auml; CRICKET CLUB</h1>');
document.write('</div>');
document.write('<div id="topnav">');
document.write('<ul class="lavaLampWithImage" id="1">');
	if (pageName=="index.html" || pageName=="")
		{document.write('<li class="current"><a href="index.html">Home</a></li>');}
	else 
		{document.write('<li><a href="index.html">Home</a></li>');}
	
		
	if (pageName=="members.html")
		{document.write('<li class="current"><a href="members.html">Members</a></li>');}
	else 
		{document.write('<li><a href="members.html">Members</a></li>');}
		
	if (pageName=="fixtures.html")
		{document.write('<li class="current"><a href="fixtures.html">Fixtures</a></li>');}
	else 
		{document.write('<li><a href="fixtures.html">Fixtures</a></li>');}
	
	if (pageName=="expense_form.html")
		{document.write('<li class="current"><a href="gallery.html">Expense form</a></li>');}
	else 
		{document.write('<li><a href="expense_form.html">Expense form</a></li>');}
	
	if (pageName=="join_us.html")
		{document.write('<li class="current"><a href="join_us.html">Join Us</a></li>');}
	else 
		{document.write('<li><a href="join_us.html">Join Us</a></li>');}
	
	if (pageName=="contact.html")
		{document.write('<li class="current"><a href="contact.html">Contacts</a></li>');}
	else 
		{document.write('<li><a href="contact.html">Contacts</a></li>');}
	document.write('</ul>');
document.write('</div>');
document.write('</div>');